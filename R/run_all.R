for (s in c("R/01_data.R", "R/02_explore.R", "R/03_forecast.R", "R/04_evaluate.R")) {
  message("Running ", s)
  source(s, echo = FALSE)
}

raw <- list.files("data/raw", full.names = TRUE)
fwrite(data.table(file = raw, bytes = file.size(raw),
                  sha256 = sapply(raw, function(f) system2("sha256sum", f, stdout = TRUE)) |>
                    sub(pattern = " .*", replacement = "")),
       "results/input_manifest.csv")
writeLines(capture.output(sessionInfo()), "results/session_info.txt")
