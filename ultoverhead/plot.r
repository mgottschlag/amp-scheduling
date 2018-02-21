#!/usr/bin/env Rscript

library(tidyverse)
library(sqldf)

pdf(NULL) # prevent Rplot.pdf files

# Usage: plot.r <graph name> <output format>
args <- commandArgs(trailingOnly = TRUE)
graphtobuild <- ifelse(length(args) > 0, args[1], "all")
format <- ifelse(length(args) > 1, args[2], "png")
# The default pdf device does not embed fonts and produces horrible kerning.
if (format == "pdf") { device <- cairo_pdf } else { device <- NULL }

# outname returns the output file name or FALSE, depending on command line
# options (above).
outname <- function(graphname)
	ifelse(graphname == graphtobuild || graphtobuild == "all",
	       paste0(graphname, ".", format),
	       FALSE)

# Increase font size in plots for presentation.
if ((font_size <- Sys.getenv("FONT_SIZE")) != "") {
	theme_update(text = element_text(size = as.integer(font_size)))
}

log <- read_tsv("log.tsv")
# parse_datetime can't handle , as ISO8601 separator
tlog <- log %>%
	mutate(time_start = parse_datetime(stringr::str_replace(time_start, ",", ".")),
	       time_end = parse_datetime(stringr::str_replace(time_end, ",", ".")),
	       duration = as.numeric(time_end - time_start))

powermeter <- read_tsv("powermeter.tsv")
rapl <- read_tsv("rapl.tsv")
# Join powermeter data via time ranges. Ignore the first second as the power
# meter takes a bit of time to react.
power_log <- sqldf("select tlog.*, avg(power) power from tlog
		   left join powermeter on datetime(powermeter.time, 'unixepoch') > datetime(time_start, 'unixepoch', '+1 second') and powermeter.time < time_end
		   group by time_start, time_end") %>% as.tibble()

rapl_log <- sqldf("select tlog.*, avg(package) package, avg(core0) core0, avg(core1) core1, avg(core2) core2
		  from tlog
		  left join rapl on time > time_start and time < time_end
		  group by time_start, time_end") %>% as.tibble()

# Powermeter readings outside of benchmark execution.
idle_power <- sqldf("select * from powermeter where time not in (select time from powermeter, tlog where time > time_start and time < time_end)") %>% as.tibble()
avg_idle_power <- as.double(idle_power %>% summarize(mean(power)))

# Calculate "fake" asymmetric execution without migration.
select_pd <- function(data) data %>% select(type, memory_bench, cpu_ratio, memory_ratio, power, duration)
fake_asym_fn <- function(type, fast, slow)
	inner_join(fast, slow, by = c("memory_bench")) %>%
	mutate(duration = duration.x + duration.y, # Duration is sum of fast and slow
	       power = (power.x*duration.x + power.y*duration.y) / duration, # Power is weighted average
	       cpu_ratio = cpu_ratio.x, memory_ratio = memory_ratio.y,
	       type = type) %>%
	select_pd()
fake_asym <- fake_asym_fn("fake asym",
			  power_log %>% filter(type == "only fast cpu"),
			  power_log %>% filter(type == "only slow memory"))
fake_asym_p2 <- fake_asym_fn("fake asym P2",
			     power_log %>% filter(type == "only fast cpu"),
			     power_log %>% filter(type == "only slow memory (all P2)", cpu_ratio == 1))
real_asym <- power_log %>% filter(type == "fast/slow ultmigration") %>% select_pd()
real_asym_other_ccx <- power_log %>% filter(type == "fast/slow ultmigration to other CCX") %>% select_pd()

# Scale used in multiple graphs.
mk_memory_bench_scale <- function(sc)
	sc(name = "Memory Work", labels = c(pointer_chasing = "Pointer Chasing", indirect_access = "Indirect Access"))
# Labeller for "mixed" facets.
mixed_labeller <- function(title) as_labeller(function(x) paste0(title, ": ", -100 * as.double(x), "%"))

if ((file <- outname("powermeter")) != FALSE) {
	# Graph to check power meter behavior: does it reset properly between runs?
	ggplot() +
		geom_line(aes(x = time, y = power), powermeter) +
		geom_vline(aes(xintercept = time_start), tlog, color = "green") +
		geom_vline(aes(xintercept = time_end), tlog, color = "red")

	ggsave(file, width = 150, height = 20, units = "cm", limitsize = FALSE, device = device)
}

if ((file <- outname("ultoverhead")) != FALSE) {
	# Graph that compares the ultoverhead types.
	ggplot(log %>% filter(!is.na(ultoverhead))) +
		geom_col(aes(x = type, y = ultoverhead))

	ggsave(file, width = 20, height = 20, units = "cm", device = device)
}

if ((file <- outname("power")) != FALSE) {
	ggplot(data = bind_rows(fake_asym, fake_asym_p2, real_asym, real_asym_other_ccx) %>%
		      mutate(cpu_ratio = -cpu_ratio, memory_ratio = -memory_ratio),
	       mapping = aes(x = duration, y = power)) +
		geom_point(aes(color = memory_bench, shape = type), stroke = 1.3) +
		mk_memory_bench_scale(scale_color_discrete) +
		guides(fill = guide_legend(override.aes = list(shape = 21)),
		       shape = guide_legend(title = NULL)) +
		ylab("Power (W)") + xlab("Duration (s)") +
		facet_grid(cpu_ratio ~ memory_ratio, labeller = labeller(cpu_ratio = mixed_labeller("CPU"), memory_ratio = mixed_labeller("Memory")))

	ggsave(file, width = 20, height = 20, units = "cm", device = device)
}