# plumber.R
# REST API for TelQuest inventory. Run with: plumber::pr("plumber.R")$run()

library(plumber)
source("inventory.R")

# ---- API keys ---------------------------------------------------------------
# Set TELQUEST_API_KEYS in your environment as a comma-separated list:
#   TELQUEST_API_KEYS="key_for_partner_a,key_for_partner_b"
# Generate keys with: openssl::rand_bytes(32) |> paste(collapse="")
valid_keys <- function() {
  raw <- Sys.getenv("TELQUEST_API_KEYS", "")
  if (raw == "") return(character(0))
  trimws(strsplit(raw, ",", fixed = TRUE)[[1]])
}

# ---- Simple in-memory cache (refresh every 5 min) ---------------------------
.cache <- new.env(parent = emptyenv())
.cache$data       <- NULL
.cache$fetched_at <- as.POSIXct(NA)
CACHE_TTL_SECONDS <- 300

cached_inventory <- function() {
  if (is.null(.cache$data) || is.na(.cache$fetched_at) ||
      difftime(Sys.time(), .cache$fetched_at, units = "secs") > CACHE_TTL_SECONDS) {
    .cache$data       <- fetch_combined_inventory()
    .cache$fetched_at <- Sys.time()
  }
  .cache$data
}

#* @apiTitle TelQuest Inventory API
#* @apiDescription Real-time and inbound inventory data. Authenticate with header `X-API-Key`.
#* @apiVersion 1.0.0

#* CORS + API key auth filter
#* @filter auth
function(req, res) {
  # Preflight CORS
  res$setHeader("Access-Control-Allow-Origin",  "*")
  res$setHeader("Access-Control-Allow-Methods", "GET, OPTIONS")
  res$setHeader("Access-Control-Allow-Headers", "X-API-Key, Content-Type")
  if (identical(req$REQUEST_METHOD, "OPTIONS")) {
    res$status <- 200
    return(list())
  }

  # Allow health check and docs without a key
  path <- req$PATH_INFO
  if (path %in% c("/health", "/__docs__/", "/openapi.json") ||
      startsWith(path, "/__docs__")) {
    return(plumber::forward())
  }

  key <- req$HTTP_X_API_KEY
  keys <- valid_keys()
  if (length(keys) == 0) {
    res$status <- 500
    return(list(error = "Server has no API keys configured (TELQUEST_API_KEYS env var)"))
  }
  if (is.null(key) || !(key %in% keys)) {
    res$status <- 401
    return(list(error = "Missing or invalid X-API-Key header"))
  }
  plumber::forward()
}

#* Health check (no auth required)
#* @get /health
function() {
  list(status = "ok", time = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"))
}

#* Full inventory listing with optional filters
#* @param part_number   Substring match on part number (case-insensitive)
#* @param manufacturer  Exact manufacturer match (case-insensitive)
#* @param condition     Exact condition match (case-insensitive)
#* @param in_stock_only If "true", excludes inbound items
#* @param on_sale_only  If "true", only items currently on sale
#* @param min_price     Numeric, minimum price
#* @param max_price     Numeric, maximum price
#* @param limit         Max rows to return (default 1000)
#* @param offset        Rows to skip for pagination (default 0)
#* @get /inventory
function(part_number = NULL, manufacturer = NULL, condition = NULL,
         in_stock_only = "false", on_sale_only = "false",
         min_price = NULL, max_price = NULL,
         limit = 1000, offset = 0) {

  df <- cached_inventory()
  if (is.null(df) || nrow(df) == 0) {
    return(list(count = 0, total = 0, items = list()))
  }

  if (!is.null(part_number) && nzchar(part_number)) {
    df <- df[grepl(part_number, df$part_number, ignore.case = TRUE), ]
  }
  if (!is.null(manufacturer) && nzchar(manufacturer)) {
    df <- df[tolower(df$manufacturer) == tolower(manufacturer), ]
  }
  if (!is.null(condition) && nzchar(condition)) {
    df <- df[tolower(df$condition) == tolower(condition), ]
  }
  if (tolower(in_stock_only) == "true") {
    df <- df[!df$is_inbound, ]
  }
  if (tolower(on_sale_only) == "true") {
    df <- df[isTRUE(df$on_sale) | df$on_sale %in% TRUE, ]
  }
  if (!is.null(min_price)) {
    df <- df[!is.na(df$price_numeric) & df$price_numeric >= as.numeric(min_price), ]
  }
  if (!is.null(max_price)) {
    df <- df[!is.na(df$price_numeric) & df$price_numeric <= as.numeric(max_price), ]
  }

  total <- nrow(df)
  limit  <- as.integer(limit);  offset <- as.integer(offset)
  if (offset > 0)   df <- df[-(seq_len(min(offset, nrow(df)))), , drop = FALSE]
  if (nrow(df) > limit) df <- df[seq_len(limit), , drop = FALSE]

  list(
    count       = nrow(df),
    total       = total,
    fetched_at  = format(.cache$fetched_at, "%Y-%m-%dT%H:%M:%S%z"),
    items       = df
  )
}

#* Look up a single part by exact part number
#* @param part_number:str  The exact part number
#* @get /inventory/<part_number>
function(part_number) {
  df <- cached_inventory()
  hit <- df[tolower(df$part_number) == tolower(part_number), ]
  if (nrow(hit) == 0) {
    list(found = FALSE, part_number = part_number)
  } else {
    list(found = TRUE, items = hit)
  }
}

#* Force a cache refresh (admin)
#* @post /refresh
function() {
  .cache$data       <- fetch_combined_inventory()
  .cache$fetched_at <- Sys.time()
  list(refreshed_at = format(.cache$fetched_at, "%Y-%m-%dT%H:%M:%S%z"),
       rows = if (is.null(.cache$data)) 0 else nrow(.cache$data))
}
