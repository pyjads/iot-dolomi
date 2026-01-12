return {
  name = "cert-to-jwt",
  fields = {
    { config = {
        type = "record",
        fields = {
          { private_key = { type = "string", required = true, encrypted = true, description = "RSA private key PEM" } },
          { issuer = { type = "string", required = true } },
          { expected_issuer = { type = "string", required = false } },
          { exp_seconds = { type = "number", default = 300 } },
          { include_cert_headers = { type = "boolean", default = false } },
          { roles = { type = "array", elements = { type = "string" }, default = {} } },
          { scope = { type = "string" } },
          { header_name = { type = "string", default = "Authorization" } },
          { header_prefix = { type = "string", default = "Bearer " } },
        }
    } }
  }
}
