/*
 * Main dependency: libaio-devel
 *
 * Command line to compile:
 * g++ -pthread -laio -Wall replay-startup-IO.cc -o replay-startup-IO
 */
#include <iostream>
#include <sstream>
#include <fstream>
#include <ctime>
#include <cstring>
#include <stdio.h>
#include <vector>
#include <map>
#include <csignal>
#include <pthread.h>
#include <unistd.h>
#include <math.h>
#include <fcntl.h>
#include <sys/syscall.h>
#include <libaio.h>

using namespace std;

#define DEB(A)

bool debug_mode = false;

const int OUT_FILE_SIZE = 20000000; // in bytes
//const int OUT_FILE_SIZE = 200000000; // in bytes
const string OUT_FILE_BASENAME = "replay_startup_file";

enum IO_req_type {SEQ, RAND};

struct IO_request_t {
	// id of the thread that will issue this request
	int thread_id;

	// time interval to wait before issuing this request, secs + nsecs
	timespec delta;

	// size of this request, in sectors (512 bytes per sector)
	unsigned long size;

	string action;
	IO_req_type type;
};

vector<IO_request_t> IO_requests;

struct thread_data_t {
	int id;
	pthread_cond_t cond;
	pthread_mutex_t mutex;
	bool please_start;
	int fd;
	io_context_t ctx;
	unsigned long long offset;
	unsigned int pending_io;
};

pthread_t *threads;
thread_data_t *thread_datas;
unsigned long next_rq_idx; // global index of the next request to issue
bool IO_finished;
pthread_cond_t IO_fin_cond;
pthread_mutex_t IO_fin_mutex;

void do_sync_read(thread_data_t *data, void *odirect_buf)
{
	DEB(cout<<"pread "<<IO_requests[next_rq_idx].size
	    <<" offset "<<data->offset<<endl);

	if (pread(data->fd, odirect_buf,
		  512 * IO_requests[next_rq_idx].size,
		  data->offset) < 0) {
		cout<<"Thread "<<data->id<<" failed reading"<<endl;
		exit(1);
	}
}

void do_async_read(thread_data_t *data, void *odirect_buf)
{
	struct iocb* iocbs = new iocb[1];

	memset(iocbs, 0, sizeof(iocb));

	// submit read request
	io_prep_pread(iocbs, data->fd, odirect_buf,
		      512 * IO_requests[next_rq_idx].size,
		      data->offset);
	int res = io_submit(data->ctx, 1, &iocbs);
	if(res < 0) {
		cout<<"io_submit error for thread "<<data->id<<endl;
		exit(1);
	}
	data->pending_io++;
}

void issue_next_rq(thread_data_t *data)
{
	nanosleep(&IO_requests[next_rq_idx].delta, 0);

	if (debug_mode) {
		cout<<"Rq "<<next_rq_idx
		    <<", Id "<<data->id
		    <<", Size "<<IO_requests[next_rq_idx].size
		    <<", Type "<<(IO_requests[next_rq_idx].type == SEQ ?
				  "Seq" : "Rand")
		    <<", Action "<<IO_requests[next_rq_idx].action
		    <<endl;
		goto end;
	}

	/*
	 * Intentionally allocate a new buffer for (direct) I/O,
	 * without ever deallocating it. To simulate more realistic
	 * I/O for a start-up phase.
	 */
	void *odirect_buf;
	if (posix_memalign(&odirect_buf, 512, 512 *
			   IO_requests[next_rq_idx].size)) {
		cout<<"Failed to allocate O_DIRECT buffer"
		    <<endl;
		exit(1);
	}

	if (IO_requests[next_rq_idx].type == SEQ) {
		if (data->offset >=
		    OUT_FILE_SIZE - 512 * IO_requests[next_rq_idx].size)
			data->offset = 0;
	} else // preserve 512-byte alignment in memory
		data->offset =
			(rand() %
			 (OUT_FILE_SIZE / 512 -
			  IO_requests[next_rq_idx].size)) * 512;

	if (next_rq_idx + 1 < IO_requests.size() &&
	    IO_requests[next_rq_idx].action == "RA")
		do_async_read(data, odirect_buf);
	else {
		if (data->pending_io > 0) {
			struct io_event events[data->pending_io];

			DEB(cout<<"Thread "<<data->id<<": rq "
			    <<next_rq_idx<<" waiting for "
			    <<data->pending_io
			    <<" pending IOs"
			    <<endl);
			int ret = io_getevents(data->ctx, data->pending_io,
					       data->pending_io, events, 0);
			if(ret < 0) {
				cout<<"io_getevents error "<<ret<<" for thread "
				    <<data->id
				    <<", rq "<<next_rq_idx
				    <<endl;
				exit(1);
			}
			data->pending_io = 0;
		}

		do_sync_read(data, odirect_buf);
	}
	data->offset += 512 * IO_requests[next_rq_idx].size;

end:
	next_rq_idx++;
}

// these go one at a time, actually
void *thread_worker(void *p)
{
	struct thread_data_t *data = (struct thread_data_t *)p;

	DEB(cout<<"Thread "<<syscall(SYS_gettid)<<" started"<<endl);
	while (true) {
		pthread_mutex_lock(&data->mutex);
		while (!data->please_start && !IO_finished) {
			DEB(cout<<"Thread "<<data->id<<" blocked"<<endl);
			pthread_cond_wait(&data->cond, &data->mutex);
		}
		pthread_mutex_unlock(&data->mutex);

		if (IO_finished)
			return 0;

		data->please_start = false;

		DEB(cout<<"Thread "<<data->id<<" starting from line "
		    <<next_rq_idx<<endl);

		while (true) {
			if (next_rq_idx == IO_requests.size()) {
				DEB(cout<<"Thread "<<data->id
				    <<": finished reading trace"<<endl);
				pthread_mutex_lock(&IO_fin_mutex);
				IO_finished = true;
				pthread_cond_signal(&IO_fin_cond);
				pthread_mutex_unlock(&IO_fin_mutex);
				return 0;
			}

			int id = IO_requests[next_rq_idx].thread_id;
			if (id != data->id) {
				DEB(cout<<"Thread "<<data->id
				    <<", next rq has id "<<id<<endl);
				pthread_mutex_lock(&thread_datas[id].mutex);
				thread_datas[id].please_start = true;
				pthread_cond_signal(&thread_datas[id].cond);
				pthread_mutex_unlock(&thread_datas[id].mutex);
				break;
			}

			issue_next_rq(data);
		}
	}

	return 0;
}

void sig_handler(int signo) { }

ifstream::pos_type get_filesize(const string &filename)
{
    ifstream in(filename, ifstream::ate | ifstream::binary);
    if (!in)
	    return 0;
    return in.tellg();
}

int main(int argc, char *argv[])
{
	if (argc < 3 || !strcmp(argv[1], "-h")) {
		cout<<"Synopsis:"<<endl
		    <<"./replay-startup-IO <trace file name> <fake-file dir>"
		    <<" [create_files]"
		    <<endl;
		return 1;
	}

	srand(time(0));

	string line;
	ifstream infile(argv[1]);
	if (!infile) {
		cout<<"Failed to open file "<<argv[1]<<endl;
		return 1;
	}

	string outdir(argv[2]);

	// number of threads that will replay I/O: one thread per
	// process doing I/O in the input file
	int nr_threads = 0;

	stringstream ss;
	string word;

	/*
	 * Map between unique names of processes doing I/O in the
	 * input file and identifiers (indexes) of the threads that
	 * will replay the I/O
	 */
	map<string, int> procs_threads_map;

	while (getline(infile, line))
	{
		stringstream ls(line);
		IO_request_t rq;

		string next_proc_name;
		ls>>next_proc_name;

		if (procs_threads_map.count(next_proc_name) == 0) {
			procs_threads_map[next_proc_name] = nr_threads;
			DEB(cout<<"Created id "<<nr_threads<<endl);
			nr_threads++;
		}

		rq.thread_id = procs_threads_map[next_proc_name];

		double deltaT;
		// time to wait before issuing this I/O request
		ls>>deltaT;

		// store in a timespec structure, to use nanosleep
		double int_part;
		rq.delta.tv_sec = modf(deltaT, &int_part);
		rq.delta.tv_nsec = int_part;

		ls>>rq.size;

		string buffer;
		// throw away next field, containing rq position
		ls>>buffer;

		ls>>buffer;
		if (buffer == "Seq")
			rq.type = SEQ;
		else
			rq.type = RAND;

		// throw away two other, unused fields
		ls>>buffer>>buffer;

		ls>>rq.action;

		DEB(cout<<"Id "<<rq.thread_id
		    <<", Type "
		    <<(rq.type == SEQ ? "Seq" : "Rand")
		    <<", Action "<<rq.action
		    <<endl);

		IO_requests.push_back(rq);
	}
	infile.close();

	IO_requests[0].delta.tv_sec = IO_requests[0].delta.tv_nsec = 0;

	if (pthread_cond_init(&IO_fin_cond, 0)) {
		cout<<"Failed to init condition variable IO_finished"<<endl;
		return 1;
	}
	if (pthread_mutex_init(&IO_fin_mutex, 0)) {
		cout<<"Failed to init mutex IO_finished"<<endl;
		return 1;
	}

	threads = new pthread_t[nr_threads];
	thread_datas = new thread_data_t[nr_threads];

	// create buffer of OUT_FILE_SIZE bytes with random values
	char *bigbuf = new char[OUT_FILE_SIZE];

	/*
	 * create per-thread files to read, if needed
	 */
	for (int i = 0 ; i < nr_threads ; i++) {
		string filepath(outdir + "/" +
				OUT_FILE_BASENAME + to_string(i));

		if (get_filesize(filepath) == OUT_FILE_SIZE)
			continue;

		if (argc < 4 || strcmp(argv[3], "create_files")) {
			cout<<"File "<<filepath
			    <<" does not exist or has wrong size"
			    <<endl;
			cout<<"To fix this, just invoke me appending the "
			    <<"create_files option too"<<endl;

			return 1;
		}

		cout<<"Creating file "<<filepath<<endl;

		ofstream f(filepath);
		if (!f) {
			cout<<"Failed to create file"<<endl;
			return 1;
		}
		f.write(bigbuf, OUT_FILE_SIZE);

		if (!f) {
			cout<<"Failed to write file content"<<endl;
			return 1;
		}

		f.close();
	}

	if (argc == 4 && !strcmp(argv[3], "create_files"))
		return 0;

	/*
	 * create and init:
	 * - threads
	 * - mutexes and condition variables
	 *
	 * This preparation phase even emulates a little better what
	 * whould happen in the start-up of a real
	 * multi-process/thread application.
	 */
	for (int i = 0 ; i < nr_threads ; i++) {
		string filepath(outdir + "/" +
				OUT_FILE_BASENAME + to_string(i));
		thread_datas[i].fd = open(filepath.c_str(), O_RDONLY|O_DIRECT);
		int ret = posix_fadvise(thread_datas[i].fd,
					0, 0, POSIX_FADV_DONTNEED);
		memset(&thread_datas[i].ctx, 0, sizeof(thread_datas[i].ctx));

		if(io_setup(1, &thread_datas[i].ctx) < 0) {
			cout<<"io_setup error for thread "<<i<<endl;
			return 1;;
		}

		if (ret != 0) {
			cout<<"Error setting no cache for thread "<<i<<endl;
			exit(1);
		}

		if (pthread_cond_init(&thread_datas[i].cond, 0)) {
			cout<<"Failed to init condition variable "<<i
			    <<", aborting"<<endl;
			return 1;
		}
		if (pthread_mutex_init(&thread_datas[i].mutex, 0)) {
			cout<<"Failed to init mutex "<<i
			    <<", aborting"<<endl;
			return 1;
		}

		thread_datas[i].id = i;
		thread_datas[i].please_start = false;
		thread_datas[i].offset = 0;
		thread_datas[i].pending_io = 0;

		ret = pthread_create(&threads[i], 0,
					 &thread_worker, &thread_datas[i]);

		DEB(cout<<"Created thread "<<i<<endl);

		if (ret != 0) {
			cout<<"Error creating thread "<<i<<endl;
			exit(1);
		}
	}

	thread_datas[0].please_start = true;
	pthread_cond_signal(&thread_datas[0].cond);

	pthread_mutex_lock(&IO_fin_mutex);
	while (!IO_finished)
		pthread_cond_wait(&IO_fin_cond, &IO_fin_mutex);
	pthread_mutex_unlock(&IO_fin_mutex);

	for (int i = 0 ; i < nr_threads ; i++)
		pthread_cond_signal(&thread_datas[i].cond);

	for (int i = 0 ; i < nr_threads ; i++)
		pthread_join(threads[i], 0);

	return 0;
}
