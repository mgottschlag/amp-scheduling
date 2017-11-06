#include "swp.h"
#include "swp_util.h"
#include "../ultmigration.h"

#include <stdlib.h>
#include <stdio.h>

#include <map>

static bool externally_registered;
static double miss_rate_threshold;

struct Mark {
	double miss_rate = 0;

	ult_thread_type thread_type() const {
		return miss_rate > miss_rate_threshold ? ULT_SLOW : ULT_FAST;
	}
};

static std::map<std::string, Mark> marks;

static void print_marks() {
	printf("Mark / miss rate:\n");
	for (const auto& kv : marks) {
		printf("\t%s: %f (%s)\n",
				kv.first.c_str(), kv.second.miss_rate,
				kv.second.thread_type() == ULT_SLOW ? "slow" : "fast");
	}
}

extern "C" void swp_init() {
	// Read marks from the configuration file.
	FILE *f = fopen(getenv("SWP_CFG"), "r");
	if (f == nullptr) {
		perror("couldn't open $SWP_CFG");
		exit(-1);
	}
	char node[100]; double misses;
	while (fscanf(f, "\"%100[^\"]\" %lf\n", node, &misses) != EOF) {
		marks[node].miss_rate = misses;
	}
	fclose(f);

	char *threshold_env = getenv("SWP_THRESHOLD");
	if (threshold_env)
		miss_rate_threshold = strtod(threshold_env, nullptr);
	if (!threshold_env || miss_rate_threshold == 0) {
		fprintf(stderr, "$SWP_THRESHOLD not set\n");
		exit(-1);
	}

	print_marks();

	if (ult_registered())
		externally_registered = true;
	else {
		ult_register_klt();
		externally_registered = false;
	}
	swp_mark("swp_init", nullptr);
}

extern "C" void swp_mark(const char *id, const char *pos) {
	std::string name = swp::section_name(id, pos);
	const auto& mark = marks[name];
	ult_migrate(mark.thread_type());
}

extern "C" void swp_deinit() {
	if (!externally_registered)
		ult_unregister_klt();
}