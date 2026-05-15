# inventory.R
# Shared inventory-fetching logic — extracted from app.R so both Shiny and
# the plumber API can call the same code.

library(httr)
library(jsonlite)
library(openssl)
library(digest)

# ---- Credentials (READ FROM ENVIRONMENT, never hardcode) --------------------
# Set these in a .Renviron file or via systemd/Docker env vars:
#   NETSUITE_ACCOUNT, NETSUITE_CONSUMER_KEY, NETSUITE_CONSUMER_SECRET,
#   NETSUITE_TOKEN_ID, NETSUITE_TOKEN_SECRET
NS <- list(
  deployment_url = "https://586038.restlets.api.netsuite.com/app/site/hosting/restlet.nl?script=3612&deploy=1",
  rest_url       = "https://586038.restlets.api.netsuite.com/app/site/hosting/restlet.nl",
  script_id      = "3612",
  deploy_id      = "1",
  account        = Sys.getenv("NETSUITE_ACCOUNT",         "586038"),
  consumer_key   = Sys.getenv("NETSUITE_CONSUMER_KEY"),
  consumer_secret= Sys.getenv("NETSUITE_CONSUMER_SECRET"),
  token_id       = Sys.getenv("NETSUITE_TOKEN_ID"),
  token_secret   = Sys.getenv("NETSUITE_TOKEN_SECRET")
)

INVENTORY_QUERY <- "
  SELECT
    customrecord_bbl.custrecord_bbl_brokerbin_part_number,
    item.description,
    customlist_awa_brand.name              AS manufacturer,
    customlist_awa_condition.name          AS Condition,
    CASE
      WHEN customrecord_bbl.custrecord_bbl_listed_brokerbin_quantity <= 250
      THEN customrecord_bbl.custrecord_bbl_listed_brokerbin_quantity
      ELSE 250
    END                                    AS qty,
    CONCAT('$', customrecord_bbl.custrecord_bbl_update_brokerbin_price),
    CONCAT('https://www.telquestintl.com/', item.urlcomponent) AS Link,
    customrecord_bbl.custrecord_promotion_exp_date
  FROM customrecord_bbl
  LEFT JOIN item                     ON customrecord_bbl.custrecord_bbl_item    = item.id
  LEFT JOIN customlist_awa_brand     ON item.custitem_awa_brand                 = customlist_awa_brand.id
  LEFT JOIN customlist_awa_condition ON item.custitem_awa_condition             = customlist_awa_condition.id
  WHERE customrecord_bbl.custrecord_bbl_listed_brokerbin_quantity > 0
    AND customrecord_bbl.custrecord_bbl_main_listing = '1'
"

# ---- OAuth 1.0a (TBA) header builder ----------------------------------------
build_auth_header <- function() {
  nonce     <- paste0(sample(c(letters, LETTERS, 0:9), 16, TRUE), collapse = "")
  timestamp <- as.character(as.integer(Sys.time()))
  method    <- "HMAC-SHA256"
  version   <- "1.0"

  base_string <- paste0(
    "POST&", URLencode(NS$rest_url, reserved = TRUE), "&",
    URLencode(paste0(
      "deploy=",                 NS$deploy_id,
      "&oauth_consumer_key=",    NS$consumer_key,
      "&oauth_nonce=",           nonce,
      "&oauth_signature_method=",method,
      "&oauth_timestamp=",       timestamp,
      "&oauth_token=",           NS$token_id,
      "&oauth_version=",         version,
      "&script=",                NS$script_id
    ), reserved = TRUE)
  )

  hashkey <- paste0(
    URLencode(NS$consumer_secret, reserved = TRUE), "&",
    URLencode(NS$token_secret,    reserved = TRUE)
  )
  signature <- base64_encode(hmac(hashkey, base_string, algo = "sha256", raw = TRUE))

  paste0(
    'OAuth realm="', NS$account, '",',
    'oauth_consumer_key="',     NS$consumer_key, '",',
    'oauth_token="',            NS$token_id,     '",',
    'oauth_signature_method="', method,          '",',
    'oauth_timestamp="',        timestamp,       '",',
    'oauth_nonce="',            nonce,           '",',
    'oauth_version="',          version,         '",',
    'oauth_signature="',        URLencode(signature, reserved = TRUE), '"'
  )
}

# ---- Public functions -------------------------------------------------------
fetch_realtime_inventory <- function() {
  res <- POST(
    NS$deployment_url,
    body = toJSON(list(query = INVENTORY_QUERY), auto_unbox = TRUE),
    add_headers(
      "Content-Type"  = "application/json",
      "Authorization" = build_auth_header()
    )
  )
  if (status_code(res) != 200) {
    stop("NetSuite returned ", status_code(res), ": ", content(res, "text"))
  }

  df <- as.data.frame(fromJSON(content(res, "text")), stringsAsFactors = FALSE)
  base_names <- c("part_number","description","manufacturer","condition",
                  "quantity","price","link","promotion_exp_date")
  ncols <- min(ncol(df), length(base_names))
  colnames(df)[1:ncols] <- base_names[1:ncols]
  if (ncol(df) < length(base_names)) {
    for (n in base_names[(ncol(df)+1):length(base_names)]) df[[n]] <- NA
  }
  df$inventory_type <- "real-time"
  df$is_inbound     <- FALSE
  df
}

fetch_inbound_inventory <- function() {
  csv_url <- "https://www.telquestintl.com/site/Daily%20Inventory%20Lists/TelQuest%20Inbound%20Inventory.csv"
  res <- GET(csv_url)
  if (status_code(res) != 200) return(NULL)

  df <- read.csv(text = content(res, "text", encoding = "UTF-8"),
                 stringsAsFactors = FALSE)
  colnames(df) <- trimws(colnames(df))

  pick <- function(pattern) {
    idx <- which(grepl(pattern, colnames(df), ignore.case = TRUE))[1]
    if (is.na(idx)) NA else df[, idx]
  }

  out <- data.frame(
    part_number   = pick("part|item|number"),
    description   = pick("desc"),
    manufacturer  = pick("manuf|brand|make"),
    condition     = pick("condition|grade"),
    quantity      = suppressWarnings(as.numeric(pick("qty|quantity"))),
    price         = as.character(pick("price|cost")),
    link          = "",
    promotion_exp_date = NA,
    inventory_type = "inbound",
    is_inbound     = TRUE,
    stringsAsFactors = FALSE
  )
  out$quantity[is.na(out$quantity)] <- 1
  out$quantity <- pmin(out$quantity, 250)

  # Normalize price formatting
  num <- gsub("[^0-9.]", "", out$price)
  out$price <- ifelse(num == "" | is.na(suppressWarnings(as.numeric(num))),
                      "Call", paste0("$", num))
  out
}

fetch_combined_inventory <- function() {
  rt <- tryCatch(fetch_realtime_inventory(), error = function(e) {
    message("Real-time fetch failed: ", e$message); NULL
  })
  ib <- tryCatch(fetch_inbound_inventory(),  error = function(e) {
    message("Inbound fetch failed: ", e$message); NULL
  })

  combined <- rbind(rt, ib)
  if (is.null(combined) || nrow(combined) == 0) return(combined)

  # Compute on-sale flag
  today <- Sys.Date()
  parse_date_safe <- function(s) {
    s <- as.character(s)
    if (is.null(s) || length(s) == 0 || is.na(s) || s == "" ||
        tolower(s) == "null") return(NA)
    for (fmt in c("%Y-%m-%d", "%m/%d/%Y", "%d/%m/%Y", "%Y/%m/%d",
                  "%m-%d-%Y", "%d-%m-%Y", "%Y-%m-%dT%H:%M:%S")) {
      d <- suppressWarnings(as.Date(s, format = fmt))
      if (!is.na(d)) return(d)
    }
    NA
  }
  combined$on_sale <- vapply(seq_len(nrow(combined)), function(i) {
    if (combined$is_inbound[i]) return(FALSE)
    d <- combined$promotion_exp_date[i]
    parsed <- parse_date_safe(d)
    !is.na(parsed) && parsed >= today
  }, logical(1))

  combined$price_numeric <- suppressWarnings(
    as.numeric(gsub("[^0-9.]", "", combined$price))
  )
  combined
}
