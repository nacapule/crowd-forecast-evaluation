RSCRIPT = Rscript

.PHONY: all fetch data fb scores experiments analyze qa test lint clean

all: fetch data fb scores experiments qa test

fetch:
	$(RSCRIPT) scripts/00_fetch.R

data:
	$(RSCRIPT) scripts/01_build_db.R

fb:
	$(RSCRIPT) scripts/03_build_fb.R

scores:
	$(RSCRIPT) scripts/04_scores.R

experiments:
	$(RSCRIPT) scripts/05_experiments.R

analyze:
	quarto render analysis/scoring-calibration.qmd
	quarto render analysis/aggregation.qmd

qa:
	$(RSCRIPT) scripts/02_qa_report.R

test:
	$(RSCRIPT) -e 'out <- testthat::test_dir("tests/testthat", stop_on_failure = TRUE)'

lint:
	$(RSCRIPT) -e 'res <- lintr::lint_dir("."); print(res); if (length(res) > 0) quit(status = 1)'

clean:
	rm -f data/db/*.duckdb data/db/*.duckdb.wal
