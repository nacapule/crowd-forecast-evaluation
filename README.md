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

Status: data layer (acquisition, normalization, QA). Scoring, calibration, and
aggregation experiments to follow.

## Reproducing

Everything runs locally in R against a DuckDB database built from the raw files.

```
make fetch    # verify raw data files (prints download instructions if missing)
make data     # build the DuckDB analysis schema from raw files
make qa       # run the QA gate and write qa/qa_report.md
make test     # unit tests
```

Harvard Dataverse sits behind a browser-verification wall, so the raw GJP files
cannot be fetched by script. `make fetch` prints per-file instructions; download
the files in a browser from the dataset page and place them in `data/raw/`.
Every file is then verified against `data/manifest.csv` (size and MD5) before
anything downstream will run. No raw data is committed to this repository.

## Layout

```
R/          functions (fetch verification, ingest, QA)
scripts/    pipeline entry points, run via make
tests/      testthat unit tests (synthetic fixtures; no raw data required)
data/       manifest.csv (committed); raw/ and db/ (local only, gitignored)
docs/       data notes
qa/         generated QA reports (committed)
```

## Data notes

See [docs/data-notes.md](docs/data-notes.md) for the source schemas, the
experimental-condition structure of the GJP tournament, and the exclusion rules
applied when building the analysis schema.
