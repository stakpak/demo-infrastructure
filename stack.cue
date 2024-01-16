package main

import (
	"stakpak.dev/devx/v1"
	"stakpak.dev/devx/v1/traits"
	"stakpak.dev/devx/v2alpha1"
	"stakpak.dev/devx/v1/transformers/terraform"
	"stakpak.dev/devx/v1/transformers/terraform/aws"
	"stakpak.dev/devx/v1/transformers/terraform/helm"
	"stakpak.dev/devx/v1/transformers/terraform/k8s"
	"stakpak.dev/devx/k8s/stacks"
	esc "stakpak.dev/devx/k8s/services/eso/components"
	esh "stakpak.dev/devx/k8s/services/eso/helpers"
	certmc "stakpak.dev/devx/k8s/services/certm/components"
	certmh "stakpak.dev/devx/k8s/services/certm/helpers"
	argocd "stakpak.dev/devx/k8s/services/argocd"
	argoapp "stakpak.dev/devx/k8s/services/argocd/components"
)

let awsRegion = "eu-north-1"
let awsAccount = "540379201213"

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

builders: v2alpha1.#Environments & {
	env1: StandardEnvironmentBuilder & {
		config: name: "env1"
	}
	env2: StandardEnvironmentBuilder & {
		config: name: "env2"
	}
}

// Reusable environment builders
StandardEnvironmentBuilder: {
	// environment config
	config: {
		name:          string
		tfStateBucket: string | *"stakpak-demo-terraform-state"
	}

	// specify build output
	drivers: terraform: output: dir: ["deploy", config.name]

	// local vars
	let terraformNetworkLayer = terraform.#SetOutputSubdir & {
		subdir: "network"
	} & terraform.#SetS3Backend & {
		s3: {
			region: awsRegion
			bucket: config.tfStateBucket
			key:    "paymob/\(config.name)/infrastructure/network"
		}
	}

	let terraformClusterLayer = terraform.#SetOutputSubdir & {
		subdir: "cluster"
	} & terraform.#SetS3Backend & {
		s3: {
			region: awsRegion
			bucket: config.tfStateBucket
			key:    "paymob/\(config.name)/infrastructure/cluster"
		}
	}

	let terraformPlatformLayer = terraform.#SetOutputSubdir & {
		subdir: "platform"
	} & terraform.#SetS3Backend & {
		s3: {
			region: awsRegion
			bucket: config.tfStateBucket
			key:    "paymob/\(config.name)/infrastructure/platform"
		}
	}

	let terraformResourcesLayer = terraform.#SetOutputSubdir & {
		subdir: "resources"
	} & terraform.#SetS3Backend & {
		s3: {
			region: awsRegion
			bucket: config.tfStateBucket
			key:    "paymob/\(config.name)/infrastructure/resources"
		}
	}

	components: {
		mainStore: users: default: username:  "\(config.name)-secrets-user"
		certIssuer: users: default: username: "\(config.name)-route53-user"
	}
	flows: {
		"terraform/add-vpc": pipeline: [
			terraformNetworkLayer,
			aws.#AddVPC & {
				vpc: name: config.name
				$resources: terraform: module: "vpc_\(vpc.name)": {
					version: "5.5.1"
				}
			},
		]
		"terraform/add-eks": pipeline: [
			terraformClusterLayer,
			aws.#AddKubernetesCluster & {
				k8s: name:         config.name
				aws: region:       awsRegion
				eks: instanceType: "t3.xlarge"
			},
		]
		"terraform/helm": pipeline: [
			terraformPlatformLayer,
			helm.#AddHelmRelease,
			aws.#AddHelmProvider & {
				k8s: name:   config.name
				aws: region: awsRegion
			},
		]
		"kubernetes/k8s": pipeline: [
			terraformResourcesLayer,
			k8s.#AddKubernetesResources,
			aws.#AddKubernetesProvider & {
				k8s: name:   config.name
				aws: region: awsRegion
			},
		]
		"terraform/aws-iam": pipeline: [
			terraformResourcesLayer,
			aws.#AddIAMUser,
			aws.#AddIAMPermissions,
			aws.#AddKubernetesProvider & {
				k8s: name:   config.name
				aws: region: awsRegion
			},
		]
		"terraform/aws-iam-k8s": {
			match: labels: secretTarget: "k8s"
			pipeline: [
				terraformResourcesLayer,
				k8s.#AddIAMUserSecret,
				aws.#AddKubernetesProvider & {
					k8s: name:   config.name
					aws: region: awsRegion
				},
			]
		}
		"terraform/aws-route53": pipeline: [
			terraformResourcesLayer,
			aws.#AddKubernetesGatewayRoute53 & {
				k8s: {
					service: {
						name:      "ingress-nginx-controller"
						namespace: "ingress-nginx"
					}
				}
			},
		]
	}

	// Common tasks runner
	taskfile: tasks: {
		check: {
			desc: "Check if the environment is properly configured"
			run:  "once"
			preconditions: [
				{
					sh:  "terraform -h"
					msg: "terraform is not installed, make sure terraform cli is installed (check https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli#install-terraform)"
				},
				{
					sh:  "aws sts get-caller-identity"
					msg: "unable to authenticate to your AWS account, make sure AWS cli v2 is installed (check https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) and that your credentials are configured"
				},
			]
			cmds: ["echo \"All looks good, ready to apply!\""]
		}
		let layers = ["network", "cluster", "platform", "resources"]
		for layer in layers {
			"init-\(layer)": {
				desc: "Init \(config.name) layer"
				deps: ["check"]
				dir: "deploy/\(config.name)/\(layer)"
				cmds: ["terraform init"]
			}
			"apply-\(layer)": {
				env: AWS_REGION: awsRegion
				desc: "Apply \(config.name) layer"
				deps: ["init-\(layer)"]
				dir: "deploy/\(config.name)/\(layer)"
				cmds: ["terraform apply"]
			}
			"plan-\(layer)": {
				desc: "Plan \(config.name) layer"
				env: AWS_REGION: awsRegion
				deps: ["init-\(layer)"]
				dir: "deploy/\(config.name)/\(layer)"
				cmds: ["terraform plan"]
			}
			"destroy-\(layer)": {
				desc: "Destroy \(config.name) layer"
				env: AWS_REGION: awsRegion
				deps: ["init-\(layer)"]
				dir: "deploy/\(config.name)/\(layer)"
				cmds: ["terraform destroy"]
			}
			"output-\(layer)": {
				desc: "Display output of \(config.name) layer"
				env: AWS_REGION: awsRegion
				dir: "deploy/\(config.name)/\(layer)"
				cmds: ["terraform output -json"]
			}
		}

		"apply-all": {
			desc: "Apply all infrastructure layers"
			cmds: [
				for layer in layers {
					{
						task: "apply-\(layer)"
					}
				},
			]
		}

		let reverseLayers = ["resources", "platform", "cluster"]
		"destroy-all": {
			cmds: [
				for layer in reverseLayers {
					{
						task: "destroy-\(layer)"
					}
				},
			]
		}

		"update-kubeconfig": {
			desc: "Setup access to AWS Kubernetes cluster."
			env: AWS_REGION: awsRegion
			preconditions: [
				{
					sh:  "aws sts get-caller-identity"
					msg: "unable to authenticate to your Azure account, make sure AWS cli is installed (check https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) and that your credentials are configured"
				},
			]
			cmds: ["aws eks update-kubeconfig --name \(config.name)"]
		}
	}
}
