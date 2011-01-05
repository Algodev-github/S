#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>

#define MIN_SIZE		(64 << 20)	/* byte */
#define MAX_SIZE		(256 << 20)
#define MIN_SLEEP		1		/* ms */
#define MAX_SLEEP		200
#define SCALED_RAND(min, max)	(int)((double)rand() *			\
				((max) - (min)) / RAND_MAX + (min))

#define MAX_READ_SIZE		(1 << 20)
unsigned char buffer[MAX_READ_SIZE];

sig_atomic_t wait_signal = 1;
int fd;

unsigned long long total_bytes;

void generic_reader(void)
{
	size_t size;
	ssize_t bytes_red;
	__useconds_t slpt;

	while (wait_signal == 1) {
		size = SCALED_RAND(MIN_SIZE, MAX_SIZE);
		while (size > 0 && wait_signal == 1) {
			bytes_red = read(fd, buffer, size < MAX_READ_SIZE ?
					 size : MAX_READ_SIZE);
			if (bytes_red == 0) {
				/* assume that files are long enough that
				* caching effects are negligible (e.g.,
				* with 3 files of 1GB each, after all the
				* readers reach the end 3GB of data have
				* made it through the system buffer
				* cache...) */
				lseek(fd, 0, SEEK_SET);
			} else if (bytes_red < 0) {
				printf("Error while reading from input\n");
				exit(-1);
			}
			total_bytes += bytes_red;
			size -= bytes_red;
		}
		slpt = SCALED_RAND(MIN_SLEEP, MAX_SLEEP);
		usleep(slpt * 1000);
	}
	printf("%llu\n", total_bytes);
}

void sighandler(int signum)
{
	(void)signum;
	wait_signal = 0;
}

int main(int argc, char *argv[])
{
	if (argc != 2) {
		printf("Usage: reader <file>\n");
		exit(-1);
	}

	fd = open(argv[1], O_RDONLY);
	if (fd == -1) {
		printf("Unable to open %s\n", argv[1]);
		exit(-1);
	}

	if (signal(SIGUSR1, sighandler) == SIG_ERR) {
		printf("Unable to assign an handler to SIGUSR1\n");
		exit(-1);
	}

	generic_reader();

	return 0;
}

