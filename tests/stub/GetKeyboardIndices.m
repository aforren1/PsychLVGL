function [idx, names, infos] = GetKeyboardIndices(varargin)
% GETKEYBOARDINDICES  Test stub, not Psychtoolbox. The devices plv_stub_input
%   'devices' set, with the info fields PsychHID fills on Linux.
    plv_stub_input('call', 'GetKeyboardIndices', varargin);
    idx = plv_stub_input('get', 'kIdx');
    names = plv_stub_input('get', 'kNames');
    infos = cell(1, numel(idx));
    for k = 1:numel(idx)
        infos{k} = struct('index', idx(k), 'product', names{k}, ...
                          'usageName', 'slave keyboard', 'interfaceID', 20 + k);
    end
end
