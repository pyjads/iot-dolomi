local cjson  = require "cjson.safe"
local pkey   = require "resty.openssl.pkey"
local digest = require "resty.openssl.digest"

local CertToJwtHandler = {
  PRIORITY = 1200,
  VERSION  = "2.0.0",
}


local function b64url(s)
  local b = ngx.encode_base64(s)
  return (b:gsub("+","-"):gsub("/","_"):gsub("=+$",""))
end


local function load_privkey(conf)
  local pem = conf.private_key
  if pem and pem:sub(1,1) == "/" then
    kong.log.debug("Loading private key from file: ", pem)
    local f, err = io.open(pem, "r")
    if not f then
      kong.log.err("failed to open key file: ", err)
      return nil, err
    end
    local content = f:read("*a")
    f:close()
    if not content or #content == 0 then
      kong.log.err("private key file empty: ", pem)
      return nil, "empty private key file"
    end
    -- trim BOM/whitespace just in case
    content = content:gsub("^%s+", ""):gsub("%s+$", "")
    return content
  end
  return pem
end


local function sign_rs256(conf, signing_input)
  local privkey_pem, err = load_privkey(conf)
  if not privkey_pem then
    return nil, err
  end

  local key, err = pkey.new(privkey_pem, { format = "PEM" }) -- load private key
  if not key then
    kong.log.err("failed to load RSA key: ", perr or "unknown error")
    kong.log.err("first 50 chars of PEM: ", privkey_pem:sub(1,50))
    return nil, perr
  end

  local d, err = digest.new("sha256")
  if not d then
    return nil, "failed to init digest: " .. (err or "unknown")
  end

  assert(d:update(signing_input))
  local sig, err = key:sign(d)
  if not sig then
    return nil, "failed to sign: " .. (err or "unknown")
  end

  return b64url(sig)
end

local function make_jwt(conf, header_tbl, payload_tbl)
  local header_json  = cjson.encode(header_tbl)  or "{}"
  local payload_json = cjson.encode(payload_tbl) or "{}"

  local h64 = b64url(header_json)
  local p64 = b64url(payload_json)
  local signing_input = h64 .. "." .. p64

  local sig64, err = sign_rs256(conf, signing_input)
  if not sig64 then
    return nil, "jwt signing failed: " .. (err or "unknown")
  end

  return signing_input .. "." .. sig64
end

function CertToJwtHandler:access(conf)

  local verify = ngx.var.ssl_client_verify
  if verify ~= "SUCCESS" then
    return kong.response.exit(401, { message = "Client certificate required" })
  end


  local subject = ngx.var.ssl_client_s_dn or ""
  local issuer  = ngx.var.ssl_client_i_dn or ""
  local serial  = ngx.var.ssl_client_serial or ""

  kong.log.debug("Client cert subject: ", subject)
  kong.log.debug("Client cert issuer: ", issuer)


  local issuer_cn = issuer:match("CN=([^,]+)")
  if conf.expected_issuer and issuer_cn ~= conf.expected_issuer then
    kong.log.err("Issuer mismatch: got CN=", issuer_cn, " expected CN=", conf.expected_issuer)
    return kong.response.exit(403, { message = "Invalid certificate issuer" })
  end


  local now = ngx.time()
  local exp = now + (conf.exp_seconds or 300)

  local payload = {
    iss           = conf.issuer or "kong",
    sub           = serial ~= "" and serial or subject,
    iat           = now,
    exp           = exp,
    device_dn     = subject,
    device_issuer = issuer,
    device_serial = serial,
    roles         = conf.roles,
    scope         = conf.scope,
  }

  local header = { typ = "JWT", alg = "RS256" }

  local token, err = make_jwt(conf, header, payload)
  if not token then
    return kong.response.exit(500, { message = err })
  end

  kong.log.debug("Generated RS256 JWT for client")

  local hdr_name   = conf.header_name   or "Authorization"
  local hdr_prefix = conf.header_prefix or "Bearer "
  kong.service.request.set_header(hdr_name, hdr_prefix .. token)

  if conf.include_cert_headers then
    kong.service.request.set_header("X-Device-DN",     subject)
    kong.service.request.set_header("X-Device-Issuer", issuer)
    kong.service.request.set_header("X-Device-Serial", serial)
  end
end

return CertToJwtHandler
