# run.R — entry point. Run with: Rscript run.R
library(plumber)

port <- as.integer(Sys.getenv("PORT", "8000"))
host <- Sys.getenv("HOST", "0.0.0.0")

pr <- plumb("plumber.R")
pr$run(host = host, port = port)
