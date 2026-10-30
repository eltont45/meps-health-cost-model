# 02_model.R
# Two-part GLM (logistic + gamma) of annual healthcare cost for privately
# insured adults 18-64, with cost concentration, validation, stop-loss, and PMPM tables.
# Requires meps_cohort.rds, created by 01_clean.R.

library(tidyverse)
cohort <- readRDS("meps_cohort.rds")

dx_vars <- c("CHDDX", "ANGIDX", "MIDX", "OHRTDX", "STRKDX", "CANCERDX",
             "DIABDX_M18", "EMPHDX", "ASTHDX", "ARTHDX", "HIBPDX", "CHOLDX")

# Adults only; recode 1 = yes / 2 = no into 1/0; drop the few with missing answers
adults <- cohort %>%
  filter(AGE24X >= 18) %>%
  mutate(across(all_of(dx_vars),
                ~ case_when(.x == 1 ~ 1L, .x == 2 ~ 0L, TRUE ~ NA_integer_))) %>%
  drop_na(all_of(dx_vars))

nrow(filter(cohort, AGE24X >= 18))   # adults before dropping missing
nrow(adults)                         # adults after
table(adults$HIBPDX, useNA = "ifany")   # should show only 0s and 1s

model_data <- adults %>%
  mutate(
    any_spend = as.integer(TOTEXP24 > 0),
    age_band  = cut(AGE24X, breaks = c(17, 34, 49, 64),
                    labels = c("18-34", "35-49", "50-64")),
    sex       = factor(SEX, levels = c(1, 2), labels = c("Male", "Female")),
    region    = factor(REGION24, levels = 1:4,
                       labels = c("Northeast", "Midwest", "South", "West")),
    n_chronic = factor(pmin(rowSums(across(all_of(dx_vars))), 4),
                       levels = 0:4, labels = c("0", "1", "2", "3", "4+"))
  )

table(model_data$n_chronic)

# ---- Cost concentration (adults 18-64) ----
total_cost <- sum(model_data$TOTEXP24)
n_people <- nrow(model_data)

share_top <- function(pct) {
  k <- ceiling(n_people * pct)
  sum(sort(model_data$TOTEXP24, decreasing = TRUE)[1:k]) / total_cost
}

share_top(0.01)
share_top(0.05)
share_top(0.10)

1 - share_top(0.5)   # share of cost from the bottom half of people

conc <- model_data %>%
  arrange(desc(TOTEXP24)) %>%
  mutate(pct_people = row_number() / n(),
         pct_cost   = cumsum(TOTEXP24) / sum(TOTEXP24))

p_conc <- ggplot(conc, aes(pct_people, pct_cost)) +
  geom_line(linewidth = 1) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed") +
  scale_x_continuous(labels = scales::percent) +
  scale_y_continuous(labels = scales::percent) +
  labs(title = "Healthcare spending is highly concentrated",
       subtitle = "Privately insured adults 18-64, MEPS 2024 (unweighted)",
       x = "Share of people (highest spenders first)",
       y = "Share of total spending")

p_conc
ggsave("concentration_curve.png", p_conc, width = 7, height = 5, dpi = 300)

set.seed(42)
train_idx <- sample(nrow(model_data), size = round(0.7 * nrow(model_data)))
train <- model_data[train_idx, ]
test  <- model_data[-train_idx, ]

# Baseline: age, sex, region
freq0 <- glm(any_spend ~ age_band + sex + region, data = train, family = binomial)
sev0  <- glm(TOTEXP24 ~ age_band + sex + region,
             data = filter(train, TOTEXP24 > 0), family = Gamma(link = "log"))

# With chronic conditions
freq1 <- glm(any_spend ~ age_band + sex + region + n_chronic,
             data = train, family = binomial)
sev1  <- glm(TOTEXP24 ~ age_band + sex + region + n_chronic,
             data = filter(train, TOTEXP24 > 0), family = Gamma(link = "log"))

summary(freq1)
summary(sev1)

test <- test %>%
  mutate(pred0 = predict(freq0, test, type = "response") * predict(sev0, test, type = "response"),
         pred1 = predict(freq1, test, type = "response") * predict(sev1, test, type = "response"))

decile_table <- function(col) {
  test %>%
    mutate(decile = ntile(.data[[col]], 10)) %>%
    group_by(decile) %>%
    summarise(avg_pred = mean(.data[[col]]), avg_actual = mean(TOTEXP24))
}

decile_table("pred0")   # baseline
decile_table("pred1")   # with chronic conditions

summary(sev0)

mean(train$TOTEXP24); mean(test$TOTEXP24)

thresholds <- c(50000, 100000, 250000)

map_dfr(thresholds, ~ tibble(
  threshold        = .x,
  n_over           = sum(model_data$TOTEXP24 > .x),
  excess_share     = sum(pmax(model_data$TOTEXP24 - .x, 0)) / sum(model_data$TOTEXP24),
  excess_pmpm      = mean(pmax(model_data$TOTEXP24 - .x, 0)) / 12
))

model_data %>%
  group_by(n_chronic) %>%
  summarise(n = n(), avg_annual = mean(TOTEXP24), pmpm = mean(TOTEXP24) / 12)

dec <- test %>%
  mutate(decile = ntile(pred1, 10)) %>%
  group_by(decile) %>%
  summarise(Predicted = mean(pred1), Actual = mean(TOTEXP24)) %>%
  pivot_longer(c(Predicted, Actual), names_to = "type", values_to = "avg_cost")

p_decile <- ggplot(dec, aes(factor(decile), avg_cost, fill = type)) +
  geom_col(position = "dodge") +
  scale_y_continuous(labels = scales::dollar) +
  labs(title = "Predicted vs. actual cost by decile",
       subtitle = "Test set, adults 18-64 (unweighted)",
       x = "Decile of predicted cost (1 = lowest)",
       y = "Average annual cost", fill = NULL)
p_decile
ggsave("decile_chart.png", p_decile, width = 7, height = 5, dpi = 300)

results <- map_dfr(1:20, function(s) {
  set.seed(s)
  idx <- sample(nrow(model_data), round(0.7 * nrow(model_data)))
  tr <- model_data[idx, ]
  te <- model_data[-idx, ]
  f <- glm(any_spend ~ age_band + sex + region + n_chronic,
           data = tr, family = binomial)
  v <- glm(TOTEXP24 ~ age_band + sex + region + n_chronic,
           data = filter(tr, TOTEXP24 > 0), family = Gamma(link = "log"))
  te <- te %>% mutate(pred = predict(f, te, type = "response") *
                        predict(v, te, type = "response"))
  tibble(seed = s, actual_to_expected = sum(te$TOTEXP24) / sum(te$pred))
})

summary(results$actual_to_expected)

set.seed(1)
folds <- sample(rep(1:5, length.out = nrow(model_data)))

cv_pred <- map_dfr(1:5, function(k) {
  tr <- model_data[folds != k, ]
  te <- model_data[folds == k, ]
  f <- glm(any_spend ~ age_band + sex + region + n_chronic, data = tr, family = binomial)
  v <- glm(TOTEXP24 ~ age_band + sex + region + n_chronic,
           data = filter(tr, TOTEXP24 > 0), family = Gamma(link = "log"))
  te %>% mutate(pred = predict(f, te, type = "response") * predict(v, te, type = "response"))
})

cv_deciles <- cv_pred %>%
  mutate(decile = ntile(pred, 10)) %>%
  group_by(decile) %>%
  summarise(avg_pred = mean(pred), avg_actual = mean(TOTEXP24))

print(cv_deciles)
write_csv(cv_deciles, "cv_deciles.csv")

cv_long <- cv_deciles %>%
  pivot_longer(c(avg_pred, avg_actual), names_to = "type", values_to = "avg_cost") %>%
  mutate(type = recode(type, avg_pred = "Predicted", avg_actual = "Actual"))

p_cv <- ggplot(cv_long, aes(factor(decile), avg_cost, fill = type)) +
  geom_col(position = "dodge") +
  scale_y_continuous(labels = scales::dollar) +
  labs(title = "Predicted vs. actual cost by decile (5-fold cross-validation)",
       subtitle = "Privately insured adults 18-64, MEPS 2024 (unweighted)",
       x = "Decile of predicted cost (1 = lowest)",
       y = "Average annual cost", fill = NULL)

p_cv
ggsave("decile_chart_cv.png", p_cv, width = 7, height = 5, dpi = 300)

stop_loss <- map_dfr(thresholds, ~ tibble(
  threshold    = .x,
  n_over       = sum(model_data$TOTEXP24 > .x),
  excess_share = sum(pmax(model_data$TOTEXP24 - .x, 0)) / sum(model_data$TOTEXP24),
  excess_pmpm  = mean(pmax(model_data$TOTEXP24 - .x, 0)) / 12
))
print(stop_loss)
write_csv(stop_loss, "stop_loss.csv")

pmpm_table <- model_data %>%
  group_by(n_chronic) %>%
  summarise(n = n(), avg_annual = mean(TOTEXP24), pmpm = mean(TOTEXP24) / 12)
print(pmpm_table)
write_csv(pmpm_table, "pmpm_by_conditions.csv")