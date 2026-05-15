FROM rstudio/plumber:latest

RUN R -e "install.packages(c('httr','jsonlite','openssl','digest'), repos='https://cloud.r-project.org')"

WORKDIR /api
COPY inventory.R plumber.R run.R /api/

EXPOSE 8000

# Env vars to set at runtime:
#   NETSUITE_CONSUMER_KEY, NETSUITE_CONSUMER_SECRET,
#   NETSUITE_TOKEN_ID, NETSUITE_TOKEN_SECRET,
#   TELQUEST_API_KEYS  (comma-separated)

CMD ["Rscript", "/api/run.R"]
