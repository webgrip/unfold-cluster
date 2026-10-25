locals {
  oidc_issuer_url                   = "https://authentik.webgrip.dev/application/o/unfold-kubernetes/"
  oidc_client_id                    = "unfold-kubernetes"
  oidc_principal_prefix             = "oidc:"
  oidc_cluster_groups               = ["unfold-admins", "unfold-viewers"]
  oidc_token_lifetime_limit_seconds = 960

  kube_authentication_patch = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "KubeAuthenticationConfig"
    configuration = {
      apiVersion = "apiserver.config.k8s.io/v1beta1"
      kind       = "AuthenticationConfiguration"
      anonymous = {
        enabled = true
        conditions = [
          { path = "/livez" },
          { path = "/readyz" },
          { path = "/healthz" },
        ]
      }
      jwt = [
        {
          issuer = {
            url       = local.oidc_issuer_url
            audiences = [local.oidc_client_id]
          }
          claimValidationRules = [
            {
              expression = "has(claims.unfold_groups) && dyn(claims.unfold_groups).exists(g, g in ${jsonencode(local.oidc_cluster_groups)})"
              message    = "the token carries no Unfold cluster group: request the unfold_kubernetes scope and hold unfold-cluster-view or unfold-cluster-operate"
            },
            {
              expression = "int(dyn(claims.exp)) - int(dyn(claims.iat)) <= ${local.oidc_token_lifetime_limit_seconds}"
              message    = "the token lives longer than ${local.oidc_token_lifetime_limit_seconds} seconds"
            },
            {
              expression = "has(claims.preferred_username) && string(dyn(claims.preferred_username)).matches('^[a-z0-9][a-z0-9._-]*$')"
              message    = "preferred_username is missing or not a plain user name"
            },
          ]
          claimMappings = {
            username = {
              claim  = "preferred_username"
              prefix = local.oidc_principal_prefix
            }
            groups = {
              claim  = "unfold_groups"
              prefix = local.oidc_principal_prefix
            }
            uid = {
              claim = "sub"
            }
          }
        },
      ]
    }
  })

  audit_write_verbs = ["create", "update", "patch", "delete", "deletecollection"]

  kube_audit_policy_patch = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "KubeAuditPolicyConfig"
    configuration = {
      apiVersion        = "audit.k8s.io/v1"
      kind              = "Policy"
      omitStages        = ["RequestReceived"]
      omitManagedFields = true
      rules = [
        {
          level = "None"
          nonResourceURLs = [
            "/healthz*",
            "/livez*",
            "/readyz*",
            "/version",
            "/metrics",
            "/openapi/*",
            "/api",
            "/api/*",
            "/apis",
            "/apis/*",
          ]
        },
        {
          level = "None"
          verbs = ["watch"]
        },
        {
          level = "None"
          resources = [
            { group = "coordination.k8s.io", resources = ["leases"] },
            { group = "", resources = ["events"] },
            { group = "events.k8s.io", resources = ["events"] },
            { group = "authorization.k8s.io", resources = ["selfsubjectaccessreviews", "selfsubjectrulesreviews"] },
          ]
        },
        {
          level      = "None"
          userGroups = ["system:nodes"]
          verbs      = ["get", "list"]
        },
        {
          level = "Metadata"
          resources = [
            { group = "", resources = ["secrets", "configmaps", "serviceaccounts/token"] },
            { group = "authentication.k8s.io", resources = ["tokenreviews"] },
          ]
        },
        {
          level = "RequestResponse"
          resources = [
            { group = "", resources = ["pods/exec", "pods/attach", "pods/portforward", "pods/proxy", "pods/ephemeralcontainers", "nodes/proxy", "services/proxy"] },
          ]
        },
        {
          level = "RequestResponse"
          verbs = local.audit_write_verbs
          resources = [
            { group = "rbac.authorization.k8s.io" },
            { group = "admissionregistration.k8s.io" },
            { group = "apiextensions.k8s.io", resources = ["customresourcedefinitions"] },
            { group = "networking.k8s.io", resources = ["networkpolicies"] },
            { group = "cilium.io", resources = ["ciliumnetworkpolicies", "ciliumclusterwidenetworkpolicies"] },
            { group = "certificates.k8s.io", resources = ["certificatesigningrequests", "certificatesigningrequests/approval"] },
            { group = "", resources = ["namespaces"] },
          ]
        },
        {
          level = "Metadata"
        },
      ]
    }
  })
}
