# distutils: language = c++
#!python
#cython: language_level=3

"""
This module re-implements functions in :module:`balanced_sequence` in cython
and obtains 25-35% speedups in common circumstances. There are likely more
speed improvements that could be made.


Issues
------
- [ ] How to deal with cython + networkx? Do we need to fix that skbuild
with pypy?


CommandLine
-----------
# Explicitly build this cython module 
# NOTE: cd to networkx repo root before running
BASE_DPATH=$(python -c "import networkx_algo_common_subtree, pathlib; print(pathlib.Path(networkx_algo_common_subtree.__file__).parent)")
cythonize -a -i $BASE_DPATH/balanced_embedding_cython.pyx

# With xdoctest this should work if networkx is installed (and this file is
# distributed with it)
# NOTE: xdoctest is not parsing this for some reason. Not sure why
xdoctest -m networkx_algo_common_subtree.balanced_sequence _cython_lcse_backend

# Which will then let you run these examples and benchmarks
xdoctest -m networkx_algo_common_subtree.balanced_embedding_cython list
python -m xdoctest networkx_algo_common_subtree.balanced_embedding_cython __doc__:0 --bench


Example
-------
>>> from networkx_algo_common_subtree.balanced_embedding_cython import _lcse_iter_cython, IdentityDictCython
>>> from networkx_algo_common_subtree.balanced_sequence import random_balanced_sequence
>>> from networkx_algo_common_subtree.balanced_embedding import _lcse_iter
>>> import operator
>>> seq1, open_to_close1 = random_balanced_sequence(300, item_type='paren')
>>> seq2, open_to_close2 = random_balanced_sequence(300, item_type='paren')
>>> open_to_close = {**open_to_close1, **open_to_close2}
>>> full_seq1 = seq1
>>> full_seq2 = seq2
>>> node_affinity = operator.eq
>>> open_to_node = IdentityDictCython()
>>> best2, value2 = _lcse_iter_cython(full_seq1, full_seq2, open_to_close, node_affinity, open_to_node)
>>> best1, value1 = _lcse_iter(full_seq1, full_seq2, open_to_close, node_affinity, open_to_node)
>>> assert value1 == value2

Benchmark
---------
>>> # xdoctest: +REQUIRES(--bench)
>>> # xdoctest: +REQUIRES(module:timerit)
>>> print((chr(10) * 3)+ ' --- BEGIN BENCHMARK ---')
>>> import timerit
>>> from networkx_algo_common_subtree import balanced_sequence as bseq
>>> from networkx_algo_common_subtree import balanced_embedding as bemb
>>> seq_len = 200
>>> seq1, open_to_close1 = bseq.random_balanced_sequence(seq_len, item_type='paren', container_type='str')
>>> seq2, open_to_close2 = bseq.random_balanced_sequence(seq_len, item_type='paren', container_type='str')
>>> open_to_close = {**open_to_close1, **open_to_close2}
>>> n = 1
>>> ti = timerit.Timerit(n, bestof=max(2, n), verbose=2)
>>> for timer in ti.reset('impl=iter-cython'):
>>>     with timer:
>>>         bemb.longest_common_balanced_embedding(seq1, seq2, open_to_close, impl='iter-cython')
>>> for timer in ti.reset('impl=iter'):
>>>     with timer:
>>>         bemb.longest_common_balanced_embedding(seq1, seq2, open_to_close, impl='iter')

>>> seq_len = 1000
>>> seq1, open_to_close1 = bseq.random_balanced_sequence(seq_len, item_type='chr')
>>> seq2, open_to_close2 = bseq.random_balanced_sequence(seq_len, item_type='chr')
>>> open_to_close = {**open_to_close1, **open_to_close2}
>>> n = 1
>>> ti = timerit.Timerit(n, bestof=max(2, n), verbose=2)
>>> # Following specs are for my machine
>>> for timer in ti.reset('impl=iter-cython'):
>>>     with timer:
>>>         bemb.longest_common_balanced_embedding(seq1, seq2, open_to_close, impl='iter-cython')
>>> for timer in ti.reset('impl=iter'):
>>>     with timer:
>>>         bemb.longest_common_balanced_embedding(seq1, seq2, open_to_close, impl='iter')


Ignore
------

# If xdoctest does not list this, is is likely because the __doc__ is stripped
# ScikitBuild seems to do this? Not sure how to turn it off.
python -c "from networkx_algo_common_subtree import balanced_embedding_cython; print(balanced_embedding_cython.__doc__)"

"""
cimport cython

from cpython.ref cimport PyObject
from cpython.ref cimport Py_XINCREF, Py_XDECREF
from libcpp.unordered_map cimport unordered_map
from libcpp.vector cimport vector
from libcpp.string cimport string




# Template sequence types over strings and tuples
ctypedef fused SeqT:
    tuple
    str

# String only
# ctypedef str SeqT

# TODO: For the decomposition create a struct that contains the data
# cdef struct SeqTDecomp:
#     string pop_open
#     string pop_close
#     string head
#     string tail
#     string head_tail


class IdentityDictCython(dict):
    """ Used when ``open_to_node`` is unspecified """
    def __getitem__(self, key):
        return key


@cython.boundscheck(False) # turn off bounds-checking for entire function
def _lcse_iter_cython(SeqT full_seq1, SeqT full_seq2, dict open_to_close, node_affinity, open_to_node):
    """
    Depth first stack trajectory and replace try except statements with ifs
    """
    cdef float pval_h, pval_t, val3, affinity
    cdef SeqT seq1, seq2
    cdef SeqT a1, b1, head1, tail1, head_tail1
    cdef SeqT a2, b2, head2, tail2, head_tail2
    cdef SeqT subseq1, subseq2
    cdef SeqT new_head1, new_head2, new_tail1, new_tail2

    if open_to_node is None:
        open_to_node = IdentityDictCython()
    all_decomp1 = generate_all_decomp_cython(full_seq1, open_to_close, open_to_node)
    all_decomp2 = generate_all_decomp_cython(full_seq2, open_to_close, open_to_node)

    key0 = (full_seq1, full_seq2)
    frame0 = key0
    stack = [frame0]

    _results = {}
    # Populate base cases
    empty1 = type(next(iter(all_decomp1.keys())))()
    empty2 = type(next(iter(all_decomp2.keys())))()
    best = (empty1, empty2)
    base_result = (0, best)
    for seq1 in all_decomp1.keys():
        key1 = seq1
        t1, a1, b1, head1, tail1, head_tail1 = all_decomp1[key1]
        _results[(seq1, empty2)] = base_result
        _results[(head1, empty2)] = base_result
        _results[(tail1, empty2)] = base_result
        _results[(head_tail1, empty2)] = base_result

    for seq2 in all_decomp2.keys():
        key2 = seq2
        t2, a2, b2, head2, tail2, head_tail2 = all_decomp2[key2]
        _results[(empty1, seq2)] = base_result
        _results[(empty1, head2)] = base_result
        _results[(empty1, tail2)] = base_result
        _results[(empty1, head_tail2)] = base_result

    while stack:
        key = stack[-1]
        if key not in _results:
            seq1, seq2 = key

            t1, a1, b1, head1, tail1, head_tail1 = all_decomp1[seq1]
            t2, a2, b2, head2, tail2, head_tail2 = all_decomp2[seq2]

            # Case 2: The current edge in sequence1 is deleted
            try_key = (head_tail1, seq2)
            if try_key in _results:
                cand1 = _results[try_key]
            else:
                stack.append(try_key)
                continue

            # Case 3: The current edge in sequence2 is deleted
            try_key = (seq1, head_tail2)
            if try_key in _results:
                cand2 = _results[try_key]
            else:
                stack.append(try_key)
                continue

            # Case 1: The LCS involves this edge
            affinity = float(node_affinity(t1, t2))
            if affinity:
                try_key = (head1, head2)
                if try_key in _results:
                    pval_h, new_heads = _results[try_key]
                else:
                    stack.append(try_key)
                    continue

                try_key = (tail1, tail2)
                if try_key in _results:
                    pval_t, new_tails = _results[try_key]
                else:
                    stack.append(try_key)
                    continue

                new_head1, new_head2 = new_heads
                new_tail1, new_tail2 = new_tails

                subseq1 = a1 + new_head1 + b1 + new_tail1
                subseq2 = a2 + new_head2 + b2 + new_tail2

                res3 = (subseq1, subseq2)
                val3 = pval_h + pval_t + affinity
                cand3 = (val3, res3)
            else:
                cand3 = (-1, None)

            # We solved the frame
            _results[key] = max(cand1, cand2, cand3)
        stack.pop()

    found = _results[key0]
    return found


@cython.boundscheck(False) # turn off bounds-checking for entire function
@cython.wraparound(False)  # turn off negative index wrapping for entire function
# cdef PyObject** balanced_decomp_unsafe_cython(SeqT sequence, dict open_to_close):
cdef tuple balanced_decomp_unsafe_cython(SeqT sequence, dict open_to_close):
    """
    Cython version of :func:`balanced_decomp_unsafe`. 
    """
    cdef int stacklen = 1  # always +1 in the first iteration
    cdef int head_stop = 1
    cdef SeqT pop_open, pop_close, head, tail, head_tail

    cdef str tok_curr = sequence[0]
    cdef str want_close = open_to_close[tok_curr]

    for head_stop in range(1, len(sequence)):
        tok_curr = sequence[head_stop]
        stacklen += 1 if tok_curr in open_to_close else -1
        if stacklen == 0 and tok_curr == want_close:
            pop_close = sequence[head_stop:head_stop + 1]
            break

    pop_open = sequence[0:1]
    head = sequence[1:head_stop]
    tail = sequence[head_stop + 1:]
    head_tail = head + tail

    # Py_XINCREF(<PyObject*>pop_open)
    # Py_XINCREF(<PyObject*>pop_close)
    # Py_XINCREF(<PyObject*>head)
    # Py_XINCREF(<PyObject*>tail)
    # Py_XINCREF(<PyObject*>head_tail)

    # cdef PyObject* ret[5]
    # ret[:] = [<PyObject*>pop_open, <PyObject*>pop_close, <PyObject*>head, <PyObject*>tail, <PyObject*>head_tail]
    # return ret
    return (pop_open, pop_close, head, tail, head_tail)


# @cython.boundscheck(False) # turn off bounds-checking for entire function
# @cython.wraparound(False)  # turn off negative index wrapping for entire function
cdef dict generate_all_decomp_cython(SeqT seq, dict open_to_close, open_to_node):
    """
    Cython version of :func:`generate_all_decomp`.
    """
    # TODO: figure out how to replace the dict with a C++ unordered_map[SeqT, SeqT[5]]
    cdef dict all_decomp = {}
    cdef SeqT pop_open, pop_close, head, tail, head_tail
    cdef list stack = [seq]

    # TODO: figure out how to replace the list with a C++ vector for the stack
    # cdef vector[SeqT] c_stack
    # c_stack.push_back(seq)

    while stack:
        # c_stack.back()  # causes a segfault?
        # c_stack.at(c_stack.size() - 1)
        # c_stack.pop_back()

        seq = stack.pop()

        # if not all_decomp.count(seq) and seq:
        if seq not in all_decomp and seq:

            pop_open, pop_close, head, tail, head_tail = balanced_decomp_unsafe_cython(seq, open_to_close)
            node = open_to_node[pop_open[0]]
            all_decomp[seq] = (node, pop_open, pop_close, head, tail, head_tail)

            stack.append(head_tail)
            stack.append(head)
            stack.append(tail)

            # c_stack.push_back(head_tail)
            # c_stack.push_back(head)
            # c_stack.push_back(tail)

    # return <dict> all_decomp
    return all_decomp
