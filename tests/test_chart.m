function test_chart()
% TEST_CHART  Chart values, series and cursor handles, and the int32 vector
%   marshaling rule.

    PsychLVGL('Init', 240, 160);
    c = onCleanup(@() PsychLVGL('Shutdown')); %#ok<NASGU>

    scr = PsychLVGL('ScreenActive');
    ch = PsychLVGL('ChartCreate', scr);
    PsychLVGL('ObjSetSize', ch, 200, 120);
    PsychLVGL('ChartSetPointCount', ch, 8);
    PsychLVGL('ChartSetAxisRange', ch, 'LV_CHART_AXIS_PRIMARY_Y', -100, 100);
    ser = PsychLVGL('ChartAddSeries', ch, [255 0 0], 'LV_CHART_AXIS_PRIMARY_Y');

    plv_assert('a series handle is valid', PsychLVGL('IsValid', ser));
    plv_assert('a series handle is above the object handle range', ser >= 2^32);
    plv_throws('a series handle is not an object handle', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('ObjGetWidth', ser));
    plv_throws('an object handle is not a series handle', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('ChartSetNextValue', ch, ch, 1));

    % round trip through the chart's own array
    v = [-50 -10 0 5 17 42 99 100];
    PsychLVGL('ChartSetValues', ch, ser, v);
    plv_eq('ChartGetValues returns what ChartSetValues copied', ...
           PsychLVGL('ChartGetValues', ch, ser), v);
    PsychLVGL('ChartSetValues', ch, ser, int32(v(end:-1:1)));
    plv_eq('an int32 vector round trips', PsychLVGL('ChartGetValues', ch, ser), v(end:-1:1));
    PsychLVGL('ChartSetValues', ch, ser, [1 NaN 3]');
    got = PsychLVGL('ChartGetValues', ch, ser);
    plv_eq('NaN is a gap and the rest of the points are gaps too', ...
           got, [1 NaN 3 NaN NaN NaN NaN NaN]);
    plv_eq('values are truncated toward zero, as scalars are', ...
           call_get(ch, ser, [2.9 -2.9]), [2 -2 NaN NaN NaN NaN NaN NaN]);

    % the generated setters: set_next_value appends and shifts
    PsychLVGL('ChartSetValues', ch, ser, 1:8);
    PsychLVGL('ChartSetNextValue', ch, ser, 9);
    plv_eq('ChartSetNextValue shifts the plot left', ...
           PsychLVGL('ChartGetValues', ch, ser), 2:9);
    PsychLVGL('ChartSetSeriesValues', ch, ser, [10 11 12]);
    plv_eq('ChartSetSeriesValues appends like repeated SetNextValue', ...
           PsychLVGL('ChartGetValues', ch, ser), [5:9 10 11 12]);
    PsychLVGL('ChartSetAllValues', ch, ser, 7);
    plv_eq('ChartSetAllValues sets every point', ...
           PsychLVGL('ChartGetValues', ch, ser), 7 * ones(1, 8));
    % ById indexes the stored array; the plot starts at the x start point.
    PsychLVGL('ChartSetSeriesValueById', ch, ser, 2, -3);
    start = PsychLVGL('ChartGetXStartPoint', ch, ser);
    got = PsychLVGL('ChartGetValues', ch, ser);
    plv_eq('ChartSetSeriesValueById sets one stored point', got(mod(2 - start, 8) + 1), -3);

    % the heap path of the vector reader, above its 1024 element stack buffer
    PsychLVGL('ChartSetPointCount', ch, 3000);
    big = mod(0:2999, 200) - 100;
    PsychLVGL('ChartSetValues', ch, ser, big);
    plv_eq('a 3000 point vector round trips', PsychLVGL('ChartGetValues', ch, ser), big);
    PsychLVGL('ChartSetPointCount', ch, 8);

    % int32 vector marshaling errors
    plv_throws('a matrix is not a vector', 'psychlvgl:Type', ...
               @() PsychLVGL('ChartSetSeriesValues', ch, ser, ones(2, 2)));
    plv_throws('char is not a vector of numbers', 'psychlvgl:Type', ...
               @() PsychLVGL('ChartSetSeriesValues', ch, ser, 'abc'));
    plv_throws('a cell is not a vector of numbers', 'psychlvgl:Type', ...
               @() PsychLVGL('ChartSetSeriesValues', ch, ser, {1, 2}));
    plv_throws('complex values are refused', 'psychlvgl:Type', ...
               @() PsychLVGL('ChartSetSeriesValues', ch, ser, [1+2i 3]));
    plv_throws('a value above int32 is refused', 'psychlvgl:Range', ...
               @() PsychLVGL('ChartSetSeriesValues', ch, ser, [1 2^31]));
    plv_throws('a value below int32 is refused', 'psychlvgl:Range', ...
               @() PsychLVGL('ChartSetSeriesValues', ch, ser, single([1 -2^32])));
    plv_throws('NaN is refused by the generic vector rule', 'psychlvgl:Range', ...
               @() PsychLVGL('ChartSetSeriesValues', ch, ser, [1 NaN]));
    plv_throws('more values than points are refused', 'psychlvgl:Range', ...
               @() PsychLVGL('ChartSetValues', ch, ser, 1:9));
    PsychLVGL('ChartSetSeriesValues', ch, ser, zeros(1, 0));
    plv_assert('an empty vector is accepted', true);
    PsychLVGL('ChartSetValues', ch, ser, uint8([1 2 3]));
    got = PsychLVGL('ChartGetValues', ch, ser);
    plv_eq('other integer classes convert', got(1:3), [1 2 3]);

    % series and cursors belong to one chart
    ch2 = PsychLVGL('ChartCreate', scr);
    ser2 = PsychLVGL('ChartAddSeries', ch2, [0 255 0], 0);
    plv_throws('a series of another chart is refused', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('ChartSetNextValue', ch, ser2, 1));
    cur = PsychLVGL('ChartAddCursor', ch, [0 0 255], 'LV_DIR_ALL');
    PsychLVGL('ChartSetCursorPoint', ch, cur, ser, 3);
    plv_assert('a cursor handle is valid', PsychLVGL('IsValid', cur));
    plv_throws('a cursor is not a series', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('ChartSetNextValue', ch, cur, 1));

    % ChartRemoveSeries invalidates its handle
    extra = PsychLVGL('ChartAddSeries', ch, [0 0 0], 0);
    PsychLVGL('ChartRemoveSeries', ch, extra);
    plv_assert('a removed series handle is stale', ~PsychLVGL('IsValid', extra));
    plv_throws('a removed series raises InvalidHandle', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('ChartSetNextValue', ch, extra, 1));
    PsychLVGL('ChartRemoveCursor', ch, cur);
    plv_assert('a removed cursor handle is stale', ~PsychLVGL('IsValid', cur));

    % deleting the chart invalidates every series and cursor it owned
    cur = PsychLVGL('ChartAddCursor', ch, [0 0 255], 'LV_DIR_ALL');
    PsychLVGL('Update', 10, [0 0 0], 0, zeros(0, 2));
    PsychLVGL('ObjDelete', ch);
    plv_assert('the series handle dies with its chart', ~PsychLVGL('IsValid', ser));
    plv_assert('the cursor handle dies with its chart', ~PsychLVGL('IsValid', cur));
    plv_assert('a series of another chart survives', PsychLVGL('IsValid', ser2));
    plv_throws('a stale series raises InvalidHandle', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('ChartGetValues', ch2, ser));

    % a parent deletion reaches the chart's series through the delete hook
    box = PsychLVGL('ObjCreate', scr);
    ch3 = PsychLVGL('ChartCreate', box);
    ser3 = PsychLVGL('ChartAddSeries', ch3, [9 9 9], 0);
    PsychLVGL('ObjDelete', box);
    plv_assert('deleting the parent frees the series handle', ~PsychLVGL('IsValid', ser3));

    % a fresh series reuses a slot with a new generation
    ser4 = PsychLVGL('ChartAddSeries', ch2, [1 1 1], 0);
    plv_assert('a new series is valid', PsychLVGL('IsValid', ser4));
    plv_assert('the old series handle stays stale', ~PsychLVGL('IsValid', ser));

    PsychLVGL('Update', 11, [0 0 0], 0, zeros(0, 2));
    plv_assert('a chart renders without error', true);

    % Shutdown releases every handle; a new session starts clean
    PsychLVGL('Shutdown');
    PsychLVGL('Init', 240, 160);
    plv_assert('series handles do not survive Shutdown', ~PsychLVGL('IsValid', ser2));
end

function got = call_get(ch, ser, v)
    PsychLVGL('ChartSetValues', ch, ser, v);
    got = PsychLVGL('ChartGetValues', ch, ser);
end
