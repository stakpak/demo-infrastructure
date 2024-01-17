resource "kubernetes_manifest" "cluster_secret_store" {
  manifest = yamldecode(<<YAML
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: onlineboutique-custom-secret
  namespace: default
spec:
  refreshInterval: 1h          
  secretStoreRef:
    kind: ClusterSecretStore
    name: main              
  target:
    name: onlineboutique-custom-secret
  data:
    - secretKey: THE_ANSWER
      remoteRef:
        key: env1-demo-secret
  YAML
  )
}
