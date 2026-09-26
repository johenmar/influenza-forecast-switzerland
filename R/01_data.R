source("R/00_functions.R")

ili <- fread("data/raw/INFLUENZA_sentinella.csv")[
  georegion == "CH" & temporal_type == "week" & agegroup == "all" & sex == "all",
  .(week = temporal, ili = incValue)]
ili[, date := isoweek_monday(week)]
setorder(ili, date)
stopifnot(all(diff(ili$date) == 7))

ili[, y := log1p(ili)]
ili[, imputed := is.na(y)]
ili[, y := zoo::na.approx(y)]

ww <- fread("data/raw/RESPVIRUSES_wastewater.csv")[
  valueCategory == "influenza_a" & !is.na(value),
  .(plant = georegion2, day = as.IDate(temporal), load = value, pop)]
ww[, date := as.Date(day) - (as.integer(format(day, "%u")) - 1)]
ww_plant <- ww[, .(load = mean(load), pop = pop[1], n_days = .N), by = .(plant, date)]
ww_week <- ww_plant[, .(ww_load = weighted.mean(load, pop), n_plants = .N), by = date]
ww_week <- ww_week[n_plants >= 2]
ww_week[, ww := log10(ww_load + 1e10)]

weekly <- merge(ili, ww_week[, .(date, ww, n_plants)], by = "date", all.x = TRUE)
weekly[, season := season_of(date)]
weekly[, in_season := in_season(date)]

dir.create("data/processed", showWarnings = FALSE)
fwrite(weekly, "data/processed/weekly_ili_wastewater.csv")

cat(sprintf("ILI weeks: %d (%s to %s), %d imputed\n", nrow(weekly),
            min(weekly$week), max(weekly$week), sum(weekly$imputed)))
cat(sprintf("Wastewater weeks: %d (%s to %s), plants per week %d-%d\n",
            sum(!is.na(weekly$ww)), min(ww_week$date), max(ww_week$date),
            min(ww_week$n_plants), max(ww_week$n_plants)))
