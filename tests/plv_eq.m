function plv_eq(name, a, b)
% PLV_EQ  Counts one test result from an equality check.
    same = isequaln(a, b);
    plv_assert(name, same);
    if ~same
        fprintf(2, '        values differ\n');
    end
end
