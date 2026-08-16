# crowd-forecast-evaluation

How much better is a crowd of forecasters than its members, and which way of
combining their probabilities holds up out of sample?

This project scores and aggregates human probability forecasts from two public
corpora:

- **Good Judgment Project (ACE tournament, 2011–2015)** — individual-level survey
  forecasts from a four-year geopolitical forecasting tournament.
  Harvard Dataverse, [doi:10.7910/DVN/BPCDH5](https://doi.org/10.7910/DVN/BPCDH5),
  CC0 1.0.
- **ForecastBench (2024 human round)** — individual forecasts from the benchmark's
  public and superforecaster comparison groups.
  [forecastingresearch/forecastbench-datasets](https://github.com/forecastingresearch/forecastbench-datasets),
  CC BY-SA 4.0.

Two notebooks carry the analysis:

- [analysis/scoring-calibration.qmd](analysis/scoring-calibration.qmd) — how
  accurate and how calibrated these forecasters are one at a time: proper
  scores under a stated daily carry-forward protocol, reliability diagrams,
  Murphy decompositions, skill and horizon analyses, and reconciliation
  against published baselines.
- [analysis/aggregation.qmd](analysis/aggregation.qmd) — nine aggregation
  rules in an out-of-sample horse race, with every free parameter tuned on
  GJP years 1–2 and frozen before evaluation on years 3–4 and on the
  ForecastBench round.

Three findings so far. Aggregating is worth far more than choosing how:
on the held-out GJP years the best rule scores 0.204 against 0.422 for the
average member of the same crowd on the same days, and even a plain mean
captures most of that. Extremizing the pooled log odds wins there, and keeps
improving as the crowd grows where the simple mean stops. And it does not
travel: the same constant is the second-worst rule on ForecastBench's public
crowd, which — unlike the GJP independents — is already overconfident.

![Aggregation rules, out of sample](analysis/figures/horse-race.png)

## Reproducing

Everything runs locally in R against a DuckDB database built from the raw files.

```
make fetch        # verify raw data files (prints download instructions if missing)
make data         # build the DuckDB analysis schema from raw files
make fb           # add the ForecastBench per-horizon scoring layer
make scores       # apply the GJP daily carry-forward scoring protocol
make experiments  # tune, freeze, and run the aggregation horse race
make qa           # run the QA gate and write qa/qa_report.md
make test         # unit tests
make analyze      # render the analysis notebooks (requires Quarto)
```

Harvard Dataverse sits behind a browser-verification wall, so the raw GJP files
cannot be fetched by script. `make fetch` prints per-file instructions; download
the files in a browser from the dataset page and place them in `data/raw/`.
Every file is then verified against `data/manifest.csv` (size and MD5) before
anything downstream will run. No raw data is committed to this repository.

## Layout

```
R/          functions: fetch verification, ingest, scoring protocol,
            aggregation rules, experiment harness, QA, figure style
scripts/    pipeline entry points, run via make
analysis/   Quarto notebooks, generated figures, results tables
tests/      testthat unit tests (synthetic fixtures; no raw data required)
data/       manifest.csv (committed); raw/ and db/ (local only, gitignored)
docs/       data notes
qa/         generated QA reports (committed)
```

## Data notes

See [docs/data-notes.md](docs/data-notes.md) for the source schemas, the
experimental-condition structure of the GJP tournament, and the exclusion rules
applied when building the analysis schema.
