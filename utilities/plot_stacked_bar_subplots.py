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

no_pol_idx=next( (i for i, x in enumerate(scheds) if x=='none-none'), -1)

if no_pol_idx != -1:
    del scheds[no_pol_idx]
    labels = ['Cumulative avg throughput of interferers',
            'Avg throughput of target',
            'Avg total throughput (sum of bars)',
            'Avg throughput reached without any I/O control',
            'Min avg throughput to be guaranteed to target'
                ]
    legend_colors = ['turquoise', 'lightcoral', 'white', 'white', 'white']
    legend_range=5
else:
    labels = ['Cumulative avg throughput of interferers',
              'Avg throughput of target',
              'Avg total throughput (sum of bars)',
              'Min avg throughput to be guaranteed to target'
            ]
    legend_colors = ['turquoise', 'lightcoral', 'white', 'white']
    legend_range=4

colors = ['lightcoral', 'turquoise']

ind = np.arange(len(scheds))
width = 0.5

# works only with at least two subplots
f, ax = plt.subplots(1, num_sub_plots, sharey=True, sharex=True, figsize=(10, 6))

plt.subplots_adjust(top=0.86)

for axis in ax:
    axis.tick_params(axis='y', which='major', labelsize=6)
    axis.tick_params(axis='y', which='minor', labelsize=2)

f.subplots_adjust(bottom=0.2) # make room for the legend

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
        labelheight = height = rect.get_height()
        if rect.get_y() > 0 and rect.get_y() < max_thr / 150 and labelheight < max_thr / 150:
            labelheight = labelheight * 12;
        elif rect.get_y() > 0 and rect.get_y() < max_thr / 100 and labelheight < max_thr / 100:
            labelheight = labelheight * 10;

        axis.text(rect.get_x() + rect.get_width()*offset[xpos],
                      rect.get_y() + labelheight / 2.,
                      '{:.4g}'.format(height), ha=ha[xpos], va='bottom',
                      size=8)


p = [] # list of bar properties
def create_subplot(matrix, colors, axis, title, reachable_thr):
    bar_renderers = []
    ind = np.arange(matrix.shape[1])

    bottoms = np.cumsum(np.vstack((np.zeros(matrix.shape[1]), matrix)), axis=0)[:-1]

    for i, row in enumerate(matrix):
        r = axis.bar(ind, row, width=0.5, color=colors[i], bottom=bottoms[i],
                         align='edge')
        autolabel(r, axis)
        bar_renderers.append(r)

    if reachable_thr > 0:
        axis.axhline(y=float(reachable_thr), xmin=0.0, xmax=1, ls='dashed', dashes=(7, 7),
                         c='black', lw=1)

    axis.set_title(title, size=10)
    return bar_renderers

max_thr = 0
i = 0
for line in content[8:]:
    line_elems = line.split()
    numbers = line_elems[1:]

    first_row = np.asarray(numbers[::2]).astype(np.float).tolist()
    second_row = np.asarray(numbers[1::2]).astype(np.float).tolist()

    mat = np.array([first_row, second_row])

    tot_throughput = np.amax(mat.sum(axis=0))

    max_thr = max(tot_throughput, max_thr)
    i += 1

i = 0
for line in content[8:]:
    line_elems = line.split()
    numbers = line_elems[1:]

    first_row = np.asarray(numbers[::2]).astype(np.float).tolist()
    second_row = np.asarray(numbers[1::2]).astype(np.float).tolist()

    reachable_thr = 0
    if no_pol_idx != -1:
        reachable_thr = first_row[no_pol_idx] + second_row[no_pol_idx]
        del first_row[no_pol_idx]
        del second_row[no_pol_idx]

    mat = np.array([first_row, second_row])
    workload_name=line_elems[0].replace('_', ' ')
    interferers_name = re.sub(r".*vs ", '', workload_name)
    target_name = re.sub(r" vs.*", '', workload_name)
    p.extend(create_subplot(mat, colors, ax[i], interferers_name + '\n' + target_name,
                                reachable_thr))
    i += 1


ax[0].set_ylabel('Target, interferers and total throughput') # add left y label
ax[0].text(-0.02, -0.025, 'I/O policy:\nScheduler:',
        horizontalalignment='right',
        verticalalignment='top',
        transform=ax[0].transAxes)
ax[0].text(-0.02, 1.012, 'Interferers:\nTarget:',
        horizontalalignment='right',
        verticalalignment='bottom',
        transform=ax[0].transAxes)


ref_line=content[4].split()
ref_value=ref_line[-1]

if ref_value.replace('.','',1).isdigit():
    [axis.axhline(y=float(ref_value), xmin=0.0, xmax=1, ls='dashed', c='black', lw=1, dashes=(4, 6)) for axis in ax]
else:
    legend_range=legend_range-1
    no_ref_value=True


class Handler(object):
    def __init__(self, colors):
        self.colors=colors
    def legend_artist(self, legend, orig_handle, fontsize, handlebox):
        x0, y0 = handlebox.xdescent, handlebox.ydescent
        width, height = handlebox.width, handlebox.height
        patch = plt.Rectangle([x0, y0], width, height, facecolor=self.colors[1],
                                   edgecolor='none', transform=handlebox.get_transform())
        patch2 = plt.Rectangle([x0, y0], width, height/2., facecolor=self.colors[0],
                                   edgecolor='none', transform=handlebox.get_transform())
        handlebox.add_artist(patch)
        handlebox.add_artist(patch2)
        return patch

mpl.rcParams['hatch.linewidth'] = 10.0
handles = [patches.Rectangle((0,0),1,1,ec='none', facecolor=legend_colors[i]) for i in range(legend_range)]
handles[2] = patches.Rectangle((0,0),1,1)

if no_pol_idx != -1:
    handles[3] = mlines.Line2D([], [], ls='dashed', c='black', lw=1, dashes=(7, 7))
    if not no_ref_value:
        handles[4] = mlines.Line2D([], [], ls='dashed', c='black', lw=1, dashes=(4, 6))
else:
    if not no_ref_value:
        handles[3] =  mlines.Line2D([], [], ls='dashed', c='black', lw=1, dashes=(4, 6))

f.legend(handles=handles, labels=labels,
             handler_map={handles[2]: Handler(colors)},
             bbox_to_anchor=(0.5, -0.0),
             loc='lower center',
             ncol=2)

plt.yticks(list(plt.yticks()[0]) + [10])

# set the same scale on all subplots' y-axis
y_mins, y_maxs = zip(*[axis.get_ylim() for axis in ax])
for axis in ax:
    axis.set_ylim((min(y_mins), max(y_maxs)))

if len(sys.argv) > 2:
    plt.savefig(fileprefix + '.' + sys.argv[2])
else:
    plt.show()
