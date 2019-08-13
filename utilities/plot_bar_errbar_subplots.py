# Execute me with python3!
import numpy as np
import matplotlib as mpl
import matplotlib.pyplot as plt
import matplotlib.patches as patches
import matplotlib.lines as mlines
import sys
import os
import re

if len(sys.argv) < 2:
    print ("Tell me the file name please")
    sys.exit()

with open(sys.argv[1]) as f:
    content = [x.strip() for x in f.readlines()]

fileprefix = os.path.splitext(sys.argv[1])[0]

num_sub_plots=len(content)-8

headline=content[7].split()

scheds=headline[2:]

labels = ['Average latency experienced by individual I/O operations of the target group']
legend_colors = ['0.5']
legend_range=1
colors = ['0.5', '0.8']

ind = np.arange(len(scheds))
width = 0.5

# works only with at least two subplots
f, ax = plt.subplots(1, num_sub_plots, sharey=True, sharex=True, figsize=(10, 6))

plt.subplots_adjust(top=0.86)

for axis in ax:
    axis.tick_params(axis='y', which='major', labelsize=6)
    axis.tick_params(axis='y', which='minor', labelsize=2)

f.subplots_adjust(bottom=0.15) # make room for the legend

scheds = [sched.replace('-', '\n', 1) for sched in scheds]

plt.xticks(ind+width/2., scheds)

plt.suptitle(content[0].replace('# ', ''))

def autolabel(rects, axis, xpos='center'):
    """
    Attach a text label above each bar in *rects*, displaying its height.

    *xpos* indicates which side to place the text w.r.t. the center of
    the bar. It can be one of the following {'center', 'right', 'left'}.
    """

    xpos = xpos.lower()  # normalize the case of the parameter
    ha = {'center': 'center', 'right': 'left', 'left': 'right'}
    offset = {'center': 0.5, 'right': 0.57, 'left': 0.43}  # x_txt = x + w*off

    for rect in rects:
        height = rect.get_height()
        axis.text(rect.get_x() + rect.get_width()*offset[xpos],
                      rect.get_y() + rect.get_height() + max_lat/80.,
                      '{:.4g}'.format(height), ha=ha[xpos], va='bottom',
                      size=8)


p = [] # list of bar properties
def create_subplot(values, errors, colors, axis, title):
    bar_renderers = []
    ind = np.arange(len(values))

    r = axis.bar(ind, values, yerr=errors, width=0.5, alpha=0.6, ecolor='black',                         align='edge', capsize=5)
    autolabel(r, axis)
    bar_renderers.append(r)

    axis.set_title(title, size=10)
    return bar_renderers

# compute max to position labels at a fixed offset above bars
max_lat = 0
for line in content[8:]:
    line_elems = line.split()
    numbers = line_elems[1:]

    values = np.asarray(numbers[::2]).astype(np.float).tolist()
    errors = np.asarray(numbers[1::2]).astype(np.float).tolist()

    sums = [a + b for a, b in zip(values, errors)]

    local_max_lat = np.amax(sums)
    if max_lat < local_max_lat:
        max_lat = local_max_lat

i = 0
for line in content[8:]:
    line_elems = line.split()
    numbers = line_elems[1:]

    values = np.asarray(numbers[::2]).astype(np.float).tolist()
    errors = np.asarray(numbers[1::2]).astype(np.float).tolist()

    workload_name=line_elems[0].replace('_', ' ')
    interferers_name = re.sub(r".*vs ", '', workload_name)
    target_name = re.sub(r" vs.*", '', workload_name)
    p.extend(create_subplot(values, errors, colors, ax[i],
                                interferers_name + '\n' + target_name,
                                ))
    i += 1



ax[0].set_ylabel('Latency [ms]') # add left y label
ax[0].text(-0.02, -0.025, 'I/O policy:\nScheduler:',
        horizontalalignment='right',
        verticalalignment='top',
        transform=ax[0].transAxes)
ax[0].text(-0.02, 1.012, 'Interferers:\nTarget:',
        horizontalalignment='right',
        verticalalignment='bottom',
        transform=ax[0].transAxes)


f.legend(labels=labels,
             bbox_to_anchor=(0.5, -0.0),
             loc='lower center',
             ncol=2)

# set the same scale on all subplots' y-axis
y_mins, y_maxs = zip(*[axis.get_ylim() for axis in ax])
for axis in ax:
    axis.set_ylim((min(y_mins), max(y_maxs)))

if len(sys.argv) > 2:
    plt.savefig(fileprefix + '.' + sys.argv[2])
else:
    plt.show()
