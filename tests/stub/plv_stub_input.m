function varargout = plv_stub_input(cmd, varargin)
% PLV_STUB_INPUT  State behind the Psychtoolbox input stubs. Test only.
%
%   The stubs KbQueueCreate, KbQueueStart, KbQueueStop, KbQueueRelease,
%   KbEventAvail, KbEventGet, GetMouse, GetMouseWheel, GetMouseIndices,
%   GetKeyboardIndices, IsLinux, IsWin and IsOSX keep no state of their own;
%   they call this function. A test drives it with:
%
%     plv_stub_input('reset')                   defaults, empty log and queues
%     plv_stub_input('platform', 'linux')       'linux', 'windows' or 'mac'
%     plv_stub_input('push', dev, evt)          queue evt on device dev
%     plv_stub_input('wheel', clicks)           next GetMouseWheel result
%     plv_stub_input('wheelError', msg)         GetMouseWheel raises msg; '' clears
%     plv_stub_input('createError', dev, msg)   KbQueueCreate(dev, ...) raises msg
%     log = plv_stub_input('log')               struct array: name, args
%     plv_stub_input('devices', kIdx, kNames, mIdx, mNames)
%     plv_stub_input('mouseInfo', usage, ifId, loc)   per mouse, as Linux fills them
%     plv_stub_input('mouse', dev, x, y, buttons)     what GetMouse(win, dev) returns
%
%   The default mice are Linux style: 2 is the master pointer (XInput id 2),
%   7 and 9 are slave pointers attached to it (locationID 2).
%
%   Device [] is the default queue and is stored as -1.

    persistent st
    if isempty(st) || strcmp(cmd, 'reset')
        st = plv_defaults();
        if strcmp(cmd, 'reset'); return; end
    end

    switch cmd
        case 'platform'
            st.platform = varargin{1};
        case 'push'
            k = plv_key(varargin{1});
            i = find(st.qdev == k, 1);
            if isempty(i)
                st.qdev(end + 1) = k;
                st.qev{end + 1} = {};
                i = numel(st.qdev);
            end
            st.qev{i}{end + 1} = varargin{2};
        case 'wheel'
            st.wheel = varargin{1};
        case 'wheelError'
            st.wheelError = varargin{1};
        case 'createError'
            st.createErrDev = plv_key(varargin{1});
            st.createErrMsg = varargin{2};
        case 'devices'
            st.kIdx = varargin{1}; st.kNames = varargin{2};
            st.mIdx = varargin{3}; st.mNames = varargin{4};
        case 'mouseInfo'
            st.mUsage = varargin{1}; st.mIfId = varargin{2}; st.mLoc = varargin{3};
        case 'mouse'
            k = plv_key(varargin{1});
            i = find(st.pdev == k, 1);
            if isempty(i); i = numel(st.pdev) + 1; st.pdev(i) = k; end
            st.pstate{i} = varargin(2:4);
        case 'log'
            varargout{1} = st.log;

        % --- called by the stubs ---
        case 'call'
            name = varargin{1};
            args = varargin{2};
            st.log(end + 1) = struct('name', name, 'args', {args});
            switch name
                case 'KbQueueCreate'
                    dev = [];
                    if ~isempty(args); dev = args{1}; end
                    if ~isempty(st.createErrMsg) && plv_key(dev) == st.createErrDev
                        error('stub:KbQueueCreate', '%s', st.createErrMsg);
                    end
                case 'GetMouseWheel'
                    if ~isempty(st.wheelError)
                        error('stub:GetMouseWheel', '%s', st.wheelError);
                    end
                    varargout{1} = st.wheel;
                    st.wheel = 0;
                case 'GetMouse'
                    dev = [];
                    if numel(args) >= 2; dev = args{2}; end
                    i = find(st.pdev == plv_key(dev), 1);
                    if isempty(i)
                        varargout = {0, 0, [0 0 0]};
                    else
                        varargout = st.pstate{i};
                    end
            end
        case 'avail'
            i = find(st.qdev == plv_key(varargin{1}), 1);
            n = 0;
            if ~isempty(i); n = numel(st.qev{i}); end
            varargout{1} = n;
        case 'pop'
            i = find(st.qdev == plv_key(varargin{1}), 1);
            evt = [];
            if ~isempty(i) && ~isempty(st.qev{i})
                evt = st.qev{i}{1};
                st.qev{i}(1) = [];
            end
            varargout{1} = evt;
        case 'get'
            varargout{1} = st.(varargin{1});
        otherwise
            error('stub:Usage', 'plv_stub_input: unknown command %s', cmd);
    end
end

function st = plv_defaults()
    % Linux by default: with no MouseIndex that platform reads the wheel with
    % GetMouseWheel, which is what the helper tests had before this stub.
    st = struct('platform', 'linux', 'qdev', zeros(1, 0), 'qev', {{}}, ...
                'wheel', 0, 'wheelError', '', 'createErrDev', NaN, 'createErrMsg', '', ...
                'kIdx', [0 4], ...
                'kNames', {{'AT Translated Set 2 keyboard', 'USB Keyboard'}}, ...
                'mIdx', [2 7 9], ...
                'mNames', {{'Virtual core pointer', 'Logitech USB Optical Mouse', 'PixArt Mouse'}}, ...
                'mUsage', {{'master pointer', 'slave pointer', 'slave pointer'}}, ...
                'mIfId', [2 10 11], 'mLoc', [3 2 2], ...
                'pdev', zeros(1, 0), 'pstate', {{}}, ...
                'log', struct('name', {}, 'args', {}));
end

function k = plv_key(dev)
    if isempty(dev); k = -1; else; k = double(dev); end
end
