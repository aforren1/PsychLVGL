function plv_assert(name, cond)
% PLV_ASSERT  Counts one test result.
%   Subfunctions plus globals rather than nested functions: Octave does not
%   share a parent workspace with nested functions the way MATLAB does.

    global TST_PASS TST_FAIL %#ok<GVMIS>
    if cond
        TST_PASS = TST_PASS + 1;
    else
        TST_FAIL = TST_FAIL + 1;
        fprintf(2, '  FAIL  %s\n', name);
    end
end
