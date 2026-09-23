function [root, named] = plv_run_generated(plv_file, parent) %#ok<STOUT,INUSD>
% PLV_RUN_GENERATED  Runs a function that PsychLVGLXMLToM wrote, without
%   putting its folder on the path.
%   The body is evaluated here, so its nargin and outputs are this
%   function's. No test may change the load path while the MEX is loaded
%   (SPEC D35), and a new file in a folder already on the path is not seen
%   by every engine without a rehash, which is the same hazard. The local
%   names carry a plv_ prefix so the generated variables cannot clash.

    plv_lines = regexp(fileread(plv_file), '\r?\n', 'split');
    plv_head = find(strncmp(plv_lines, 'function ', 9), 1);
    plv_last = find(strcmp(strtrim(plv_lines), 'end'), 1, 'last');
    if nargin < 2
        parent = []; %#ok<NASGU>
    end
    assetDir = []; %#ok<NASGU> the generated body fills in its default
    eval(sprintf('%s\n', plv_lines{plv_head + 1:plv_last - 1}));
end
