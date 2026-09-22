function plv_throws(name, id, fn)
% PLV_THROWS  Counts one test result from an expected error identifier.
    try
        fn();
    catch e
        plv_assert(name, strcmp(e.identifier, id));
        if ~strcmp(e.identifier, id)
            fprintf(2, '        got id "%s" (%s)\n', e.identifier, e.message);
        end
        return;
    end
    plv_assert(name, false);
    fprintf(2, '        %s did not throw\n', name);
end
