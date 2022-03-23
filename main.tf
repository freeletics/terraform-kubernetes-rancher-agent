data "rancher2_cluster" "target" {
  name = var.rancher_cluster_name
}

data "rancher2_setting" "server_url" {
  name = "server-url"
}

data "rancher2_setting" "server_version" {
  name = "server-version"
}

locals {
  k8s_namespace                 = "cattle-system"
  rancher_server_url            = data.rancher2_setting.server_url.value
  rancher_agent_version         = data.rancher2_setting.server_version.value
  rancher_agent_container_image = "rancher/rancher-agent:${local.rancher_agent_version}"
}

resource "kubernetes_namespace" "cattle-system" {
  metadata {
    annotations = {
      name = "cattle-system"
    }

    labels = {
      mylabel = "cattle-system"
    }

    name = local.k8s_namespace
  }

  lifecycle {
    ignore_changes = [
      metadata.0.annotations
    ]
  }

}

resource "kubernetes_service_account" "cattle" {
  automount_service_account_token = true

  metadata {
    name      = "cattle"
    namespace = local.k8s_namespace

    annotations = {
      "field.cattle.io/description" = "Rancher 2 Agent"
    }

    labels = {
      "app.kubernetes.io/name"       = "cattle"
      "app.kubernetes.io/part-of"    = "rancher"
      "app.kubernetes.io/managed-by" = "terraform"
    }

  }
  depends_on = [
    kubernetes_namespace.cattle-system
  ]
}

resource "kubernetes_cluster_role" "cattle_admin" {
  metadata {
    name = "cattle-admin"

    annotations = {
      "field.cattle.io/description" = "Rancher 2 Agent"
    }

    labels = {
      "app.kubernetes.io/name"       = "cattle"
      "app.kubernetes.io/part-of"    = "rancher"
      "app.kubernetes.io/managed-by" = "terraform"
      "cattle.io/creator"            = "norman"
    }
  }

  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["*"]
  }

  rule {
    non_resource_urls = ["*"]
    verbs             = ["*"]
  }
}

resource "kubernetes_cluster_role" "proxy_clusterrole_kubeapiserver" {
  metadata {
    name = "proxy-clusterrole-kubeapiserver"

    annotations = {
      "field.cattle.io/description" = "Rancher 2 Proxy"
    }

    labels = {
      "app.kubernetes.io/name"       = "cattle"
      "app.kubernetes.io/part-of"    = "rancher"
      "app.kubernetes.io/managed-by" = "terraform"
      "cattle.io/creator"            = "norman"
    }
  }

  rule {
    api_groups = ["*"]
    resources  = ["nodes/metrics", "nodes/proxy", "nodes/stats", "nodes/log", "nodes/spec"]
    verbs      = ["get", "list", "watch", "create"]
  }
}

resource "kubernetes_cluster_role_binding" "proxy_role_binding_kubernetes_master" {
  metadata {
    name = "proxy-role-binding-kubernetes-master"

    labels = {
      "app.kubernetes.io/name"       = "cattle"
      "app.kubernetes.io/part-of"    = "rancher"
      "app.kubernetes.io/managed-by" = "terraform"
      "cattle.io/creator"            = "norman"
    }
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ServiceAccount"
    name      = "kube-apiserver"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.proxy_clusterrole_kubeapiserver.metadata[0].name
  }
}

resource "kubernetes_cluster_role_binding" "cattle_admin_binding" {
  metadata {
    name = "cattle-admin-binding"

    labels = {
      "app.kubernetes.io/name"       = "cattle"
      "app.kubernetes.io/part-of"    = "rancher"
      "app.kubernetes.io/managed-by" = "terraform"
      "cattle.io/creator"            = "norman"
    }
  }

  subject {
    api_group = ""
    kind      = "ServiceAccount"
    name      = "cattle"
    namespace = "cattle-system"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cattle-admin"
  }
}

resource "kubernetes_secret" "cattle_credentials" {
  metadata {
    name      = "cattle-credentials"
    namespace = local.k8s_namespace

    labels = {
      "app.kubernetes.io/name"       = "cattle"
      "app.kubernetes.io/part-of"    = "rancher"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  type = "Opaque"

  data = {
    url = local.rancher_server_url
    # Yeah... this *is* brain-dead.
    token = split(
      ".yaml",
      split("/v3/import/", data.rancher2_cluster.target.cluster_registration_token[0].manifest_url)[1]
    )[0]
  }
}

resource "kubernetes_deployment" "cattle_cluster_agent" {

  metadata {
    name      = "cattle-cluster-agent"
    namespace = local.k8s_namespace

    annotations = {
      "field.cattle.io/description"          = "Rancher 2 Cluster Agent"
      "management.cattle.io/scale-available" = "2"
    }

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/name"       = "cattle-cluster-agent"
      "app.kubernetes.io/part-of"    = "rancher"
      "app.kubernetes.io/version"    = "v${local.rancher_agent_version}"
    }
  }

  spec {
    selector {
      match_labels = {
        "app" = "cattle-cluster-agent"
      }
    }

    template {
      metadata {
        annotations = var.k8s_cluster_agent_pod_annotations
        labels = merge(
          {
            "app"                       = "cattle-cluster-agent"
            "app.kubernetes.io/name"    = "cattle-cluster-agent"
            "app.kubernetes.io/part-of" = "rancher"
            "app.kubernetes.io/version" = "v${local.rancher_agent_version}"
          },
          var.k8s_cluster_agent_pod_labels
        )
      }

      spec {
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "kubernetes.io/os"
                  operator = "In"
                  values   = ["linux"]
                }
                match_expressions {
                  key      = "eks.amazonaws.com/compute-type"
                  operator = "NotIn"
                  values   = ["fargate"]
                }
              }
            }
          }
        }
        automount_service_account_token = true
        service_account_name            = kubernetes_service_account.cattle.metadata[0].name

        container {
          name              = "cluster-register"
          image             = local.rancher_agent_container_image
          image_pull_policy = "IfNotPresent"

          env {
            name  = "CATTLE_SERVER"
            value = local.rancher_server_url
          }

          env {
            name  = "CATTLE_CA_CHECKSUM"
            value = ""
          }

          env {
            name  = "CATTLE_CLUSTER"
            value = "true"
          }

          env {
            name  = "CATTLE_K8S_MANAGED"
            value = "true"
          }

          volume_mount {
            name       = "cattle-credentials"
            mount_path = "/cattle-credentials"
            read_only  = true
          }
        }

        node_selector = var.k8s_cluster_agent_node_selector

        dynamic "toleration" {
          for_each = var.k8s_cluster_agent_tolerations
          content {
            effect   = toleration.value["effect"]
            key      = toleration.value["key"]
            operator = toleration.value["operator"]
            value    = toleration.value["value"]
          }
        }

        volume {
          name = "cattle-credentials"

          secret {
            secret_name = kubernetes_secret.cattle_credentials.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "cattle_cluster_agent" {
  metadata {
    name      = "cattle-cluster-agent"
    namespace = local.k8s_namespace

    annotations = {
      "field.cattle.io/description"          = "Rancher 2 Cluster Agent"
      "management.cattle.io/scale-available" = "2"
    }

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/name"       = "cattle-cluster-agent"
      "app.kubernetes.io/part-of"    = "rancher"
      "app.kubernetes.io/version"    = "v${local.rancher_agent_version}"
    }
  }
  spec {
    selector = {
      app = "cattle-cluster-agent"
    }
    port {
      port        = 80
      target_port = 80
      protocol    = "TCP"
      name        = "http"
    }
    port {
      port        = 443
      target_port = 444
      protocol    = "TCP"
      name        = "https-internal"
    }
  }
}
