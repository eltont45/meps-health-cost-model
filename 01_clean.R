# 01_clean.R
# Loads the MEPS 2024 Full Year Consolidated file, cleans missing-value codes,
# and builds the cohort of privately insured people under 65.
#
# BEFORE RUNNING: download the Stata version of HC-256 (h256dta.zip) from
# https://meps.ahrq.gov/data_stats/download_data_files_detail.jsp?cboPufNumber=HC-256
# Unzip it and place h256.dta in the same folder as this script.
# (The raw data is not included in this repository.)
#
# Output: meps_cohort.rds, which is read by 02_model.R

library(tidyverse)                           # data cleaning and plotting tools
library(haven)                               # reads Stata files

meps_raw <- read_dta("h256.dta")
names(meps_raw) <- toupper(names(meps_raw))  # makes names uppercase for consistency
dim(meps_raw)                                # rows (people) and columns (variables)

keep <- c("DUPERSID", "TOTEXP24", "AGE24X", "SEX", "REGION24",
          "INSCOV24", "PERWT24F", "VARSTR", "VARPSU")

setdiff(keep, names(meps_raw))               # should print character(0) if all names exist

dx_vars <- c("CHDDX", "ANGIDX", "MIDX", "OHRTDX", "STRKDX", "CANCERDX",
             "DIABDX_M18", "EMPHDX", "ASTHDX", "ARTHDX", "HIBPDX", "CHOLDX")

setdiff(dx_vars, names(meps_raw))   # should print character(0)

keep <- c(keep, dx_vars)

meps <- meps_raw %>% select(all_of(keep))

meps %>%
  select(-DUPERSID) %>%
  summarise(across(everything(), ~ sum(.x < 0, na.rm = TRUE)))

meps_clean <- meps %>%
  mutate(across(where(is.labelled), zap_labels)) %>%  # strip Stata labels
  mutate(across(-DUPERSID, ~ if_else(.x < 0, NA_real_, as.numeric(.x))))

colSums(is.na(meps_clean))
any(select(meps_clean, -DUPERSID) < 0, na.rm = TRUE)

cohort <- meps_clean %>%
  filter(INSCOV24 == 1, AGE24X < 65)          # any private insurance, under 65

nrow(cohort)
summary(cohort$TOTEXP24)
mean(cohort$TOTEXP24 == 0, na.rm = TRUE)        # share with zero spending

saveRDS(cohort, "meps_cohort.rds")