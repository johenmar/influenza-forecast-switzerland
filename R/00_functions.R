suppressPackageStartupMessages({
  library(data.table)
  library(forecast)
  library(ranger)
  library(ggplot2)
  library(patchwork)
})

probs <- c(0.1, 0.25, 0.5, 0.75, 0.9)
qcols <- paste0("q", probs * 100)

isoweek_monday <- function(x) {
  yr <- as.integer(substr(x, 1, 4))
  wk <- as.integer(substr(x, 7, 8))
  jan4 <- as.Date(paste0(yr, "-01-04"))
  jan4 - (as.integer(format(jan4, "%u")) - 1) + 7 * (wk - 1)
}

season_of <- function(date) {
  yr <- as.integer(format(date, "%G"))
  wk <- as.integer(format(date, "%V"))
  ifelse(wk >= 40, yr, yr - 1L)
}

in_season <- function(date) {
  wk <- as.integer(format(date, "%V"))
  wk >= 40 | wk <= 16
}

interval_score <- function(y, lo, hi, alpha) {
  (hi - lo) + 2 / alpha * (lo - y) * (y < lo) + 2 / alpha * (y - hi) * (y > hi)
}

wis <- function(y, q10, q25, q50, q75, q90) {
  (0.5 * abs(y - q50) +
     0.2 / 2 * interval_score(y, q10, q90, 0.2) +
     0.5 / 2 * interval_score(y, q25, q75, 0.5)) / 2.5
}

rf_features <- function(d, h, ww = FALSE, ww_delay = 2) {
  y <- d$y
  n <- length(y)
  lagv <- function(v, k) c(rep(NA, k), v)[seq_len(n)]
  leadv <- function(v, k) c(v, rep(NA, k))[k + seq_len(n)]
  target_date <- d$date + 7 * h
  f <- data.table(
    date = d$date,
    h = h,
    y0 = y,
    d1 = y - lagv(y, 1),
    d2 = lagv(y, 1) - lagv(y, 2),
    d4 = y - lagv(y, 4),
    ly = lagv(y, 52 - h) - y,
    sin_w = sin(2 * pi * as.integer(format(target_date, "%V")) / 52.18),
    cos_w = cos(2 * pi * as.integer(format(target_date, "%V")) / 52.18),
    target = leadv(y, h) - y
  )
  if (ww) {
    w <- lagv(d$ww, ww_delay)
    f[, ww0 := w]
    f[, ww_d1 := w - lagv(w, 1)]
  }
  f
}

rf_fit_predict <- function(train, test, seed = 1) {
  x <- setdiff(names(train), c("date", "h", "target"))
  set.seed(seed)
  fit <- ranger(x = train[, ..x], y = train$target, num.trees = 2000,
                min.node.size = 5, quantreg = TRUE, seed = seed)
  q <- predict(fit, test[, ..x], type = "quantiles", quantiles = probs)$predictions
  q + test$y0
}

theme_set(theme_minimal(base_size = 11) +
            theme(panel.grid.minor = element_blank(),
                  plot.title = element_text(face = "bold"),
                  legend.position = "bottom"))

model_cols <- c("Naive" = "grey55", "Seasonal naive" = "grey30",
                "ARIMA + Fourier" = "#1f78b4", "Quantile forest" = "#e6550d",
                "Ensemble" = "#6a3d9a")
