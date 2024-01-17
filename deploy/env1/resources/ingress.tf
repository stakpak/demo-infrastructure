resource "kubernetes_ingress_v1" "frontend" {
  metadata {
    name      = "frontend"
    namespace = "default"
    annotations = {
      "cert-manager.io/cluster-issuer" = "letsencrypt"
    }
  }
  spec {
    ingress_class_name = "nginx"
    tls {
      hosts = [
        "demo.guku.io",
      ]
      secret_name = "demo-guku-io-tls"
    }
    rule {
      host = "demo.guku.io"
      http {
        path {
          backend {
            service {
              name = "frontend"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
