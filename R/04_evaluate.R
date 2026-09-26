source("R/00_functions.R")

fc <- fread("results/forecasts.csv")
fc_ww <- fread("results/forecasts_wastewater.csv")
ccf_tab <- fread("results/wastewater_lead_lag.csv")

score <- function(x) {
  x[, `:=`(
    wis = wis(y_true, q10, q25, q50, q75, q90),
    ae_log = abs(y_true - q50),
    ae = abs(expm1(y_true) - expm1(q50)),
    in50 = y_true >= q25 & y_true <= q75,
    in80 = y_true >= q10 & y_true <= q90
  )]
}
score(fc)
score(fc_ww)

dm_test <- function(loss_diff, h) {
  n <- length(loss_diff)
  dbar <- mean(loss_diff)
  e <- loss_diff - dbar
  gam <- sapply(0:(h - 1), function(k) sum(e[(1 + k):n] * e[1:(n - k)]) / n)
  v <- (gam[1] + 2 * sum(gam[-1])) / n
  stat <- dbar / sqrt(v) * sqrt((n + 1 - 2 * h + h * (h - 1) / n) / n)
  2 * pt(-abs(stat), df = n - 1)
}

model_order <- names(model_cols)
fc[, model := factor(model, model_order)]
naive <- fc[model == "Naive", .(origin, h, wis_naive = wis)]
fc <- merge(fc, naive, by = c("origin", "h"))
setorder(fc, model, h, origin)

scores <- fc[, .(
  n = .N,
  wis = mean(wis),
  rel_wis = mean(wis) / mean(wis_naive),
  mae_log = mean(ae_log),
  mae_per_100k = mean(ae),
  cov50 = mean(in50),
  cov80 = mean(in80),
  dm_p_vs_naive = if (model[1] == "Naive") NA_real_ else dm_test(wis - wis_naive, h[1])
), by = .(model, h)]
fwrite(scores, "results/scores_by_horizon.csv")

fc[, season := paste0(format(origin - 120, "%Y"), "/", as.integer(format(origin - 120, "%y")) + 1)]
by_season <- fc[, .(rel_wis = mean(wis) / mean(wis_naive)), by = .(model, season)]
by_season <- dcast(by_season, model ~ season, value.var = "rel_wis")
fwrite(by_season, "results/relative_wis_by_season.csv")

overall <- fc[, .(rel_wis = mean(wis) / mean(wis_naive), mae_per_100k = mean(ae),
                  cov50 = mean(in50), cov80 = mean(in80)), by = model]
fwrite(overall, "results/scores_overall.csv")

ww_base <- fc_ww[variant == "ILI only", .(origin, h, wis_base = wis)]
fc_ww <- merge(fc_ww, ww_base, by = c("origin", "h"))
setorder(fc_ww, variant, h, origin)
ww_scores <- fc_ww[, .(
  wis = mean(wis),
  rel_wis_vs_ili_only = mean(wis) / mean(wis_base),
  mae_per_100k = mean(ae),
  cov80 = mean(in80),
  dm_p = if (variant[1] == "ILI only") NA_real_ else dm_test(wis - wis_base, h[1])
), by = .(variant, h)]
fwrite(ww_scores, "results/scores_wastewater.csv")

print(scores, digits = 3)
print(by_season, digits = 3)
print(overall, digits = 3)
print(ww_scores, digits = 3)

ex <- fc[h == 2 & season == "2024/25" & model %in% c("ARIMA + Fourier", "Quantile forest", "Ensemble")]
p4 <- ggplot(ex, aes(target_date)) +
  geom_ribbon(aes(ymin = expm1(q10), ymax = expm1(q90), fill = model), alpha = 0.25) +
  geom_ribbon(aes(ymin = expm1(q25), ymax = expm1(q75), fill = model), alpha = 0.4) +
  geom_line(aes(y = expm1(q50), colour = model), linewidth = 0.6) +
  geom_point(aes(y = expm1(y_true)), size = 0.9) +
  facet_wrap(~model, nrow = 1) +
  scale_fill_manual(values = model_cols, guide = "none") +
  scale_colour_manual(values = model_cols, guide = "none") +
  scale_x_date(date_labels = "%b") +
  labs(x = NULL, y = "ILI per 100k",
       title = "Two-week-ahead forecasts during the 2024/25 season",
       subtitle = "Median, 50% and 80% intervals; points are observed values")
ggsave("figures/fig4_forecasts_2024_25.png", p4, width = 9, height = 3.6, dpi = 200, bg = "white")

p5a <- ggplot(scores, aes(h, rel_wis, colour = model)) +
  geom_hline(yintercept = 1, linetype = 2, colour = "grey50") +
  geom_line(linewidth = 0.7) + geom_point() +
  scale_colour_manual(values = model_cols, name = NULL) +
  labs(x = "Horizon (weeks)", y = "WIS relative to naive", title = "Forecast skill (lower is better)")
p5b <- ggplot(scores, aes(h, cov80, colour = model)) +
  geom_hline(yintercept = 0.8, linetype = 2, colour = "grey50") +
  geom_line(linewidth = 0.7) + geom_point() +
  scale_colour_manual(values = model_cols, name = NULL) +
  scale_y_continuous(labels = scales::percent, limits = c(0.4, 1)) +
  labs(x = "Horizon (weeks)", y = "Coverage", title = "80% interval coverage")
ggsave("figures/fig5_scores.png", p5a + p5b + plot_layout(guides = "collect"),
       width = 9, height = 4, dpi = 200, bg = "white")

cc <- melt(ccf_tab, id.vars = "lag", measure.vars = c("level", "change"))
cc[, variable := factor(variable, c("level", "change"), c("Levels", "Weekly changes"))]
p6a <- ggplot(cc, aes(lag, value, colour = variable)) +
  geom_vline(xintercept = 0, colour = "grey70") +
  geom_line() + geom_point() +
  scale_colour_manual(values = c("#1f78b4", "#e6550d"), name = NULL) +
  labs(x = "Wastewater lead (weeks)", y = "Correlation with ILI",
       title = "Lead-lag correlation")
ww_main <- ww_scores[!grepl("seed", variant)]
ww_seed <- ww_scores[variant == "ILI only" | grepl("seed", variant)]
p6b <- ggplot(ww_main, aes(h, rel_wis_vs_ili_only)) +
  geom_hline(yintercept = 1, linetype = 2, colour = "grey50") +
  geom_line(data = ww_seed, aes(group = variant), colour = "grey80", linewidth = 0.5) +
  geom_line(aes(colour = variant), linewidth = 0.7) + geom_point(aes(colour = variant)) +
  scale_colour_manual(values = c("ILI only" = "grey40",
                                 "ILI + wastewater, 2-week delay (as published)" = "#1f78b4",
                                 "ILI + wastewater, no delay (hypothetical)" = "#9ecae1"), name = NULL) +
  coord_cartesian(ylim = c(0.9, 1.1)) +
  guides(colour = guide_legend(ncol = 1)) +
  labs(x = "Horizon (weeks)", y = "WIS relative to ILI only",
       title = "Forest with vs without wastewater",
       subtitle = "Grey: ILI only, other random seeds")
ggsave("figures/fig6_wastewater.png", p6a + p6b, width = 9, height = 4.2, dpi = 200, bg = "white")
