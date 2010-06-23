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

# dir where to find the kern tree to test make, git merge and git checkout
KERN_DIR=/home/paolo/fake_tree/linux-2.6
