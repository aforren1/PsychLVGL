function [idx, names, infos] = GetMouseIndices(varargin)
% GETMOUSEINDICES  Test stub, not Psychtoolbox. The devices plv_stub_input
%   'devices' set, with the info fields PsychHID fills on Linux.
    plv_stub_input('call', 'GetMouseIndices', varargin);
    idx = plv_stub_input('get', 'mIdx');
    names = plv_stub_input('get', 'mNames');
    usage = plv_stub_input('get', 'mUsage');
    ifId = plv_stub_input('get', 'mIfId');
    loc = plv_stub_input('get', 'mLoc');
    infos = cell(1, numel(idx));
    for k = 1:numel(idx)
        infos{k} = struct('index', idx(k), 'product', names{k}, ...
                          'usageName', usage{k}, 'interfaceID', ifId(k), ...
                          'locationID', loc(k));
    end
end
