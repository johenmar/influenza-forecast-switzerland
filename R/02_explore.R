source("R/00_functions.R")

d <- fread("data/processed/weekly_ili_wastewater.csv")
d[, date := as.Date(date)]
test_seasons <- 2023:2025

shade <- d[season %in% test_seasons & in_season, .(start = min(date), end = max(date)), by = season]

p1a <- ggplot(d, aes(date, ili)) +
  geom_rect(data = shade, aes(xmin = start, xmax = end, ymin = 0, ymax = Inf),
            inherit.aes = FALSE, fill = "#fdd0a2", alpha = 0.5) +
  geom_line(linewidth = 0.4) +
  scale_y_continuous(trans = "log1p", breaks = c(0, 10, 30, 100, 300)) +
  labs(x = NULL, y = "ILI consultations per 100k",
       title = "Influenza-like illness in Switzerland, weekly (Sentinella)",
       subtitle = "Shaded: forecast test periods (weeks 40-16 of 2023/24, 2024/25, 2025/26)")
p1b <- ggplot(d[date >= as.Date("2022-01-01")], aes(date, ww)) +
  geom_rect(data = shade, aes(xmin = start, xmax = end, ymin = -Inf, ymax = Inf),
            inherit.aes = FALSE, fill = "#fdd0a2", alpha = 0.5) +
  geom_line(linewidth = 0.4, colour = "#1f78b4", na.rm = TRUE) +
  coord_cartesian(xlim = range(d$date)) +
  labs(x = NULL, y = "log10 load", title = "Influenza A in wastewater, population-weighted mean of up to 11 plants")
ggsave("figures/fig1_series.png", p1a / p1b + plot_layout(heights = c(2, 1)),
       width = 9, height = 5.5, dpi = 200, bg = "white")

d[, wos := as.integer((date - as.Date(paste0(season, "-10-01"))) / 7)]
p2 <- ggplot(d[season >= 2013 & season <= 2025], aes(wos, ili, group = season,
                                                    colour = season %in% test_seasons)) +
  geom_line(linewidth = 0.5) +
  scale_colour_manual(values = c("grey70", "#e6550d"), labels = c("2013/14-2022/23", "Test seasons"),
                      name = NULL) +
  scale_y_continuous(trans = "log1p", breaks = c(0, 10, 30, 100, 300)) +
  labs(x = "Weeks since 1 October", y = "ILI per 100k",
       title = "One wave per winter, but timing and height vary")
ggsave("figures/fig2_seasons.png", p2, width = 7, height = 4, dpi = 200, bg = "white")

acf_dt <- function(x, lab) {
  a <- acf(x, lag.max = 60, plot = FALSE)
  data.table(lag = a$lag[-1], acf = a$acf[-1], series = lab)
}
train <- d[date < as.Date("2023-10-02")]
ac <- rbind(acf_dt(train$y, "log(ILI + 1)"), acf_dt(diff(train$y), "Weekly change"))
ac[, series := factor(series, c("log(ILI + 1)", "Weekly change"))]
ci <- 1.96 / sqrt(nrow(train))
p3 <- ggplot(ac, aes(lag, acf)) +
  geom_hline(yintercept = c(-ci, ci), linetype = 2, colour = "grey50") +
  geom_segment(aes(xend = lag, yend = 0)) +
  facet_wrap(~series, ncol = 2) +
  labs(x = "Lag (weeks)", y = "Autocorrelation",
       title = "Autocorrelation before the test period (2013-2023)")
ggsave("figures/fig3_acf.png", p3, width = 8, height = 3.2, dpi = 200, bg = "white")

ccf_tab <- rbindlist(lapply(-4:4, function(k) {
  x <- d[, .(date, in_season, dy = y - shift(y), dw = shift(ww, k) - shift(ww, k + 1),
             yl = y, wl = shift(ww, k))]
  x <- x[in_season == TRUE & date >= as.Date("2022-10-03")]
  data.table(lag = k,
             level = cor(x$yl, x$wl, use = "complete.obs"),
             change = cor(x$dy, x$dw, use = "complete.obs"),
             n = sum(complete.cases(x$dy, x$dw)))
}))
fwrite(ccf_tab, "results/wastewater_lead_lag.csv")
print(ccf_tab)
