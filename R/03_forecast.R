source("R/00_functions.R")

d <- fread("data/processed/weekly_ili_wastewater.csv")
d[, date := as.Date(date)]
H <- 1:4
test_seasons <- 2023:2025
origins <- d[season %in% test_seasons & in_season == TRUE, date]
first_origin <- min(origins)
freq <- 365.25 / 7

pre <- d[date < first_origin]
y_pre <- ts(pre$y, frequency = freq)
k_search <- rbindlist(lapply(1:4, function(k) {
  fit <- auto.arima(y_pre, xreg = fourier(y_pre, K = k), seasonal = FALSE)
  data.table(K = k, order = paste(arimaorder(fit), collapse = ","),
             drift = "drift" %in% names(coef(fit)), aicc = fit$aicc)
}))
fwrite(k_search, "results/arima_order_selection.csv")
best <- k_search[which.min(aicc)]
K <- best$K
ord <- as.integer(strsplit(best$order, ",")[[1]])
cat(sprintf("ARIMA(%s) with K = %d Fourier pairs, drift = %s\n", best$order, K, best$drift))

empirical_q <- function(err) quantile(err, probs, names = FALSE, na.rm = TRUE)

forecast_origin <- function(t) {
  tr <- d[date <= t]
  n <- nrow(tr)
  y_now <- tr$y[n]
  seas <- tr$in_season
  out <- list()

  for (h in H) {
    idx <- which(seas & seq_len(n) + h <= n)
    q <- y_now + empirical_q(tr$y[idx + h] - tr$y[idx])
    out[[length(out) + 1]] <- data.table(model = "Naive", h = h, t(q))

    idx52 <- idx[idx + h - 52 >= 1]
    sn_err <- tr$y[idx52 + h] - tr$y[idx52 + h - 52]
    q <- tr$y[n + h - 52] + empirical_q(sn_err)
    out[[length(out) + 1]] <- data.table(model = "Seasonal naive", h = h, t(q))
  }

  yt <- ts(tr$y, frequency = freq)
  fit <- Arima(yt, order = ord, xreg = fourier(yt, K = K), include.constant = best$drift)
  fc <- forecast(fit, xreg = fourier(yt, K = K, h = max(H)), level = c(50, 80))
  q <- cbind(fc$lower[, "80%"], fc$lower[, "50%"], fc$mean, fc$upper[, "50%"], fc$upper[, "80%"])
  out[[length(out) + 1]] <- data.table(model = "ARIMA + Fourier", h = H, q)

  for (h in H) {
    f <- rf_features(tr, h)
    train <- na.omit(f)
    test <- f[date == t]
    q <- rf_fit_predict(train, test, seed = h)
    out[[length(out) + 1]] <- data.table(model = "Quantile forest", h = h, q)
  }

  res <- rbindlist(out, use.names = FALSE)
  setnames(res, c("model", "h", qcols))
  res[, origin := t]
  res
}

set.seed(1)
fc <- rbindlist(lapply(origins, forecast_origin))

ens <- fc[model %in% c("ARIMA + Fourier", "Quantile forest"),
          lapply(.SD, mean), by = .(origin, h), .SDcols = qcols]
ens[, model := "Ensemble"]
fc <- rbind(fc, ens, use.names = TRUE)

fc[, target_date := origin + 7 * h]
fc <- merge(fc, d[, .(target_date = date, y_true = y)], by = "target_date")
setcolorder(fc, c("origin", "target_date", "h", "model"))
setorder(fc, model, h, origin)
fwrite(fc, "results/forecasts.csv")

ww_variants <- list(
  "ILI only" = list(ww = FALSE, delay = 2, seed = 0),
  "ILI only, seed 2" = list(ww = FALSE, delay = 2, seed = 100),
  "ILI only, seed 3" = list(ww = FALSE, delay = 2, seed = 200),
  "ILI + wastewater, 2-week delay (as published)" = list(ww = TRUE, delay = 2, seed = 0),
  "ILI + wastewater, no delay (hypothetical)" = list(ww = TRUE, delay = 0, seed = 0)
)
fc_ww <- rbindlist(lapply(origins, function(t) {
  tr <- d[date <= t]
  rbindlist(lapply(names(ww_variants), function(v) {
    rbindlist(lapply(H, function(h) {
      keep <- complete.cases(rf_features(tr, h, ww = TRUE, ww_delay = 2)[, .(ww0, ww_d1)],
                             rf_features(tr, h, ww = TRUE, ww_delay = 0)[, .(ww0, ww_d1)])
      f <- rf_features(tr, h, ww = ww_variants[[v]]$ww, ww_delay = ww_variants[[v]]$delay)[keep]
      q <- rf_fit_predict(na.omit(f), f[date == t], seed = h + ww_variants[[v]]$seed)
      data.table(variant = v, origin = t, h = h, matrix(q, nrow = 1, dimnames = list(NULL, qcols)))
    }))
  }))
}))
fc_ww[, target_date := origin + 7 * h]
fc_ww <- merge(fc_ww, d[, .(target_date = date, y_true = y)], by = "target_date")
fwrite(fc_ww, "results/forecasts_wastewater.csv")

f2 <- na.omit(rf_features(d[date <= max(origins) + 14], 2))
f2[, fold := sample(rep(1:10, length.out = .N))]
cv <- rbindlist(lapply(1:10, function(k) {
  te <- f2[fold == k]
  q <- rf_fit_predict(f2[fold != k], te, seed = 10 + k)
  data.table(origin = te$date, q50 = q[, 3], y_true = te$y0 + te$target)
}))
leak <- rbind(
  cv[origin %in% origins, .(scheme = "Random 10-fold CV", mae = mean(abs(y_true - q50)))],
  fc[model == "Quantile forest" & h == 2, .(scheme = "Rolling origin", mae = mean(abs(y_true - q50)))]
)
fwrite(leak, "results/leakage_random_cv_vs_rolling_origin.csv")
print(leak)

imp <- rbindlist(lapply(H, function(h) {
  tr <- na.omit(rf_features(d[date <= max(origins)], h))
  x <- setdiff(names(tr), c("date", "h", "target"))
  fit <- ranger(x = tr[, ..x], y = tr$target, num.trees = 2000, min.node.size = 5,
                importance = "permutation", seed = h)
  data.table(h = h, feature = names(fit$variable.importance), importance = fit$variable.importance)
}))
fwrite(dcast(imp, feature ~ paste0("h", h), value.var = "importance"), "results/forest_importance.csv")
