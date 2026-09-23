function test_images()
% TEST_IMAGES  Image handles from uint8 arrays and from OpenGL texture names,
%   and the rule that an image still shown by an image object cannot be
%   deleted.
%
%   The software variant has no OpenGL, so ImageFromTexture gives a
%   transparent image of the right size there. tests/gl/test_gl_image.m checks
%   the texture pixels on the GPU build.

    PsychLVGL('Init', 120, 90);
    c = onCleanup(@() PsychLVGL('Shutdown')); %#ok<NASGU>

    scr = PsychLVGL('ScreenActive');
    PsychLVGL('ObjSetStyleBgColor', scr, [0 0 0]);
    base = render_crc();

    rgb = zeros(20, 30, 3, 'uint8');
    rgb(:, :, 1) = 255;                  % red
    rgb(1:10, :, 2) = 255;               % top half yellow
    img = PsychLVGL('ImageFromArray', rgb);
    plv_assert('an image handle is valid', PsychLVGL('IsValid', img));
    plv_assert('an image handle is above the object handle range', img >= 2^32);

    obj = PsychLVGL('ImageCreate', scr);
    PsychLVGL('ImageSetSrc', obj, img);
    plv_eq('the source width is the column count', PsychLVGL('ImageGetSrcWidth', obj), 30);
    plv_eq('the source height is the row count', PsychLVGL('ImageGetSrcHeight', obj), 20);
    shown = render_crc();
    plv_assert('an image changes the rendered frame', shown ~= base);

    plv_throws('an image in use cannot be deleted', 'psychlvgl:InUse', ...
               @() PsychLVGL('ImageDelete', img));
    PsychLVGL('ImageSetSrc', obj, 0);
    PsychLVGL('ImageDelete', img);
    plv_assert('ImageSetSrc 0 releases the image', ~PsychLVGL('IsValid', img));
    plv_throws('a deleted image raises InvalidHandle', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('ImageSetSrc', obj, img));
    plv_eq('the frame is back to the empty one', render_crc(), base);

    % the channel layouts
    gray = PsychLVGL('ImageFromArray', uint8(magic(8)));
    rgba = PsychLVGL('ImageFromArray', cat(3, rgb, 128 * ones(20, 30, 'uint8')));
    PsychLVGL('ImageSetSrc', obj, rgba);
    plv_eq('an RGBA image has the same size', PsychLVGL('ImageGetSrcWidth', obj), 30);
    PsychLVGL('ImageSetSrc', obj, gray);
    plv_eq('a gray image is supported', PsychLVGL('ImageGetSrcWidth', obj), 8);

    % deleting the image object releases its image
    PsychLVGL('ObjDelete', obj);
    PsychLVGL('ImageDelete', gray);
    PsychLVGL('ImageDelete', rgba);
    plv_assert('an object deletion releases its image', ~PsychLVGL('IsValid', gray));

    % array errors
    plv_throws('double is not accepted', 'psychlvgl:Type', ...
               @() PsychLVGL('ImageFromArray', rand(4, 4, 3)));
    plv_throws('two planes are not an image', 'psychlvgl:Type', ...
               @() PsychLVGL('ImageFromArray', zeros(4, 4, 2, 'uint8')));
    plv_throws('an empty array is not an image', 'psychlvgl:Range', ...
               @() PsychLVGL('ImageFromArray', zeros(0, 4, 'uint8')));

    % texture images: size and handle rules hold without a GPU
    t = PsychLVGL('ImageFromTexture', 7, 64, 32);
    obj = PsychLVGL('ImageCreate', scr);
    PsychLVGL('ImageSetSrc', obj, t);
    plv_eq('a texture image has the given width', PsychLVGL('ImageGetSrcWidth', obj), 64);
    plv_eq('a texture image has the given height', PsychLVGL('ImageGetSrcHeight', obj), 32);
    render_crc();
    plv_throws('a texture image in use cannot be deleted', 'psychlvgl:InUse', ...
               @() PsychLVGL('ImageDelete', t));
    plv_throws('texture name 0 is refused', 'psychlvgl:Range', ...
               @() PsychLVGL('ImageFromTexture', 0, 8, 8));
    plv_throws('a texture wider than the limit is refused', 'psychlvgl:Range', ...
               @() PsychLVGL('ImageFromTexture', 3, 20000, 8));
    plv_throws('an image handle is not a style', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('ObjAddStyle', obj, t));
    plv_throws('a style handle is not an image', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('ImageSetSrc', obj, PsychLVGL('StyleCreate')));
    plv_throws('an object handle is not an image', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('ImageSetSrc', obj, obj));

    % Shutdown frees an image that an object still shows
    PsychLVGL('Shutdown');
    PsychLVGL('Init', 120, 90);
    plv_assert('image handles do not survive Shutdown', ~PsychLVGL('IsValid', t));
end

function crc = render_crc()
    persistent t
    if isempty(t); t = 9000; end
    t = t + 1;
    PsychLVGL('Update', t, [0 0 0], 0, zeros(0, 2));
    t = t + 1;
    PsychLVGL('Update', t, [0 0 0], 0, zeros(0, 2));
    crc = PsychLVGL('FrameChecksum');
end
