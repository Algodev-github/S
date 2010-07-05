# If equal to 1, tracing is enabled during each test
TRACE=0

# The disk on which you are about to run the tests
HD=sda

# number of 1K blocks to read/write for each file
NUM_BLOCKS=2000000

# number of 1K blocks of the files to create for seq reading
NUM_BLOCKS_CREATE=5000000

# where files are read from or written to
BASE_DIR=/tmp/test

# file names
BASE_SEQ_FILE_PATH=$BASE_DIR/largefile
FILE_TO_RAND_READ=$BASE_DIR/verylargefile_read
FILE_TO_RAND_WRITE=$BASE_DIR/verylargefile_write

# the make, git merge and git checkout tests play with 2.6.30, 2.6.32 and
# 2.6.33. You must provide a git tree containing at least these three versions,
# and store the path to the tree in the following parameter.
KERN_DIR=/home/paolo/fake_tree/linux-2.6
#	NOTE:
#	For the make test to run without blocking, you must be sure that the
#	tree contains a valid .config for these kernels (a valid .config
#	for any of the three will do also for the others).
