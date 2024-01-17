package main

import (
	"stakpak.dev/devx/v1"
	"stakpak.dev/devx/v1/traits"
	"stakpak.dev/devx/k8s/stacks"
	esc "stakpak.dev/devx/k8s/services/eso/components"
	esh "stakpak.dev/devx/k8s/services/eso/helpers"
	certmc "stakpak.dev/devx/k8s/services/certm/components"
	certmh "stakpak.dev/devx/k8s/services/certm/helpers"
	argocd "stakpak.dev/devx/k8s/services/argocd"
	argoapp "stakpak.dev/devx/k8s/services/argocd/components"
)

awsRegion: "eu-north-1"
awsAccount: "540379201213"

// Application platform definition
stack: v1.#Stack & {
	components: {
		// VPC
		network: {
			traits.#VPC
			vpc: {
				name: string
				cidr: "10.0.0.0/16"
				subnets: {
					private: ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
					public: ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
				}
			}
		}

		// Kubernetes cluster
		cluster: {
			traits.#KubernetesCluster
			k8s: {
				name: string
				version: minor: 28
			}
			aws: vpc: name: network.vpc.name
		}

		// Clutser gateway
		gateway: {
			traits.#Gateway
			gateway: {
				name:   "default"
				public: true
				addresses: [
					"demo.guku.io",
				]
				listeners: {
					"http": {
						port:     80
						protocol: "HTTP"
					}
					"https": {
						port:     443
						protocol: "HTTPS"
					}
				}
			}
		}

		// Platform services
		stacks.KubernetesBasicStack.components
		certManager: k8s:             cluster.k8s
		externalSecretsOperator: k8s: cluster.k8s
		ingressNginx: {
			k8s: cluster.k8s
			helm: values: controller: {
				podSecurityContext: runAsNonRoot: true
				service: {
					enableHttp:  true
					enableHttps: true
					annotations: "service.beta.kubernetes.io/aws-load-balancer-type": "nlb"
				}
			}
		}
		"argo-cd": argocd.#ArgoCDChart & {
			k8s: cluster.k8s
			helm: {
				values: {
					nameOverride: "argo-cd"
					"redis-ha": enabled:          false
					controller: replicas:         1
					server: replicas:             1
					repoServer: replicas:         1
					applicationSet: replicaCount: 1
				}
			}
		}

		// Custom resource definitions to configure platform services
		mainStore: {
			$metadata: labels: secretTarget: "k8s"
			k8s: {
				cluster.k8s
				namespace: externalSecretsOperator.helm.namespace
			}
			aws: region: awsRegion

			traits.#User
			users: default: username: string
			policies: "secret-access": (esh.#ParameterStoreAWSIAMPolicy & {
				prefix: cluster.k8s.name
				aws: {
					region:  awsRegion
					account: awsAccount
				}
			}).policy

			esc.#AWSSecretStore
			secretStore: {
				name:            "main"
				scope:           "cluster"
				type:            "ParameterStore"
				accessKeySecret: users.default.password
			}
		}

		certIssuer: {
			$metadata: labels: secretTarget: "k8s"
			k8s: {
				cluster.k8s
				namespace: certManager.helm.namespace
			}
			aws: region: awsRegion

			traits.#User
			users: default: username: string
			policies: (certmh.#Route53AWSIAMPolicies).policies

			certmc.#ClusterIssuer
			certIssuer: {
				email: "george@stakpak.dev"
				dnsSolvers: [{
					selector: dnsZones: ["*.guku.io"]
					route53: {
						region:          awsRegion
						accessKeySecret: users.default.password
					}
				}]
			}
		}

		// Add apps
		apps: argoapp.#ArgoCDApplication & {
			k8s: {
				cluster.k8s
				namespace: "argo-cd"
			}
			application: {
				name: "onlineboutique"
				source: {
					repoURL:        "us-docker.pkg.dev/online-boutique-ci/charts"
					chart:          "onlineboutique"
					targetRevision: "0.8.1"
					helm: {
						releaseName: "onlineboutique"
						values: frontend: externalService: false
					}
				}
			}
		}
	}
}