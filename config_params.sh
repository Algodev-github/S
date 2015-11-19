# If equal to 1, tracing is enabled during each test
TRACE=0

# The disk on which you are about to run the tests, by default tries to peek
# the device used for /
# If it does not work or is not want you want, change it to fit your needs,
# for example:
# HD=sda
HD=$(basename `mount | grep "on / " | cut -f 1 -d " "` | sed 's/\(...\).*/\1/g')

# number of 1M blocks of the files to create for seq reading/writing
NUM_BLOCKS_CREATE_SEQ=5000

# number of 1M blocks of the files to create for rand reading/writing
# (the larger the better for randomness)
NUM_BLOCKS_CREATE_RAND=$(($NUM_BLOCKS_CREATE_SEQ * 10))

# portion, in 1M blocks, to read for each file, used only in fairness.sh
NUM_BLOCKS=2000

# where files are read from or written to
BASE_DIR=/tmp/test

# file names
BASE_SEQ_FILE_PATH=$BASE_DIR/largefile
FILE_TO_RAND_READ=$BASE_DIR/verylargefile_read
FILE_TO_RAND_WRITE=$BASE_DIR/verylargefile_write

# the make, git merge and git checkout tests play with v4.0, v4.1 and
# v4.2. You must provide a git tree containing at least these three versions,
# and store the path to the tree in the following parameter.
KERN_REMOTE=https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
KERN_DIR=$BASE_DIR/fake_tree/linux
#	NOTE:
#	For the make test to run without blocking, you must be sure that the
#	tree contains a valid .config for these kernels (a valid .config
#	for any of the three will do also for the others).

# NCQ queue depth, if undefined then no script will change the current value
NCQ_QUEUE_DEPTH=

# Mail-report parameters. A mail transfer agent (such as msmtp) and a mail
# client (such as mailx) must be installed to be able to send mail reports.
# The sender e-mail address will be the one configured as default in the
# mail client itself.
MAIL_REPORTS=0
MAIL_REPORTS_RECIPIENT=
