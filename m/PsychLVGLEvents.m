function out = PsychLVGLEvents(cmd, E, varargin)
% PSYCHLVGLEVENTS  Reads the matrix PsychLVGL('Poll') returns.
%
%   S = PsychLVGLEvents('decode', E)
%       Struct array with target, name, code, currentTarget, param, time.
%
%   R = PsychLVGLEvents('filter', E, h, 'CLICKED')
%       The rows of E whose target is h and whose code is that event. Pass []
%       for either to leave it unconstrained.
%
%   The matrix is the primary form because one mxCreateDoubleMatrix is far
%   cheaper per frame than a struct array. Decode when readability matters.

    switch lower(cmd)
        case 'decode'
            out = do_decode(E);
        case 'filter'
            out = do_filter(E, varargin{:});
        otherwise
            error('psychlvgl:Usage', 'unknown PsychLVGLEvents command "%s"', cmd);
    end
end

function S = do_decode(E)
    n = size(E, 1);
    S = repmat(struct('target', 0, 'name', '', 'code', 0, ...
                      'currentTarget', 0, 'param', 0, 'time', 0), n, 1);
    for k = 1:n
        S(k).target = E(k, 1);
        S(k).code = E(k, 2);
        try
            S(k).name = PsychLVGL('EventName', E(k, 2));
        catch
            S(k).name = sprintf('CODE_%d', E(k, 2));
        end
        S(k).currentTarget = E(k, 3);
        S(k).param = E(k, 4);
        S(k).time = E(k, 5);
    end
    if n == 0
        S = S([]);
    end
end

function R = do_filter(E, h, name)
    if nargin < 2; h = []; end
    if nargin < 3; name = []; end
    keep = true(size(E, 1), 1);
    if ~isempty(h)
        keep = keep & (E(:, 1) == h);
    end
    if ~isempty(name)
        if ischar(name)
            code = PsychLVGL('Enum', ['LV_EVENT_' strrep(upper(name), 'LV_EVENT_', '')]);
        else
            code = name;
        end
        keep = keep & (E(:, 2) == code);
    end
    R = E(keep, :);
end
