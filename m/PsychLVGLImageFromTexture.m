function img = PsychLVGLImageFromTexture(win, tex)
% PSYCHLVGLIMAGEFROMTEXTURE  An LVGL image that draws a Psychtoolbox texture.
%
%   img = PsychLVGLImageFromTexture(win, tex)
%
%   win   The onscreen window the texture belongs to.
%   tex   A Psychtoolbox texture handle. It must be a GL_TEXTURE_2D texture in
%         upright orientation. Make it with specialFlags 1 and
%         textureOrientation 1:
%
%             tex = Screen('MakeTexture', win, imageMatrix, [], 1, [], 1);
%
%   img   An image handle for PsychLVGL('ImageSetSrc', imageObject, img).
%
%   The NanoVG renderer samples the texture directly, so no pixel crosses
%   the CPU. This needs no OpenGL context of its own: call it outside
%   Screen('BeginOpenGL').
%
%   The texture stays yours. Keep it open while an image object shows it,
%   and close it only after PsychLVGL('ImageSetSrc', obj, 0) and
%   PsychLVGL('ImageDelete', img). When you change the texture contents,
%   call PsychLVGL('ObjInvalidate', imageObject) so that LVGL draws the
%   image again.
%
%   Example:
%       tex = Screen('MakeTexture', win, imread('face.png'), [], 1, [], 1);
%       img = PsychLVGLImageFromTexture(win, tex);
%       obj = PsychLVGL('ImageCreate', PsychLVGL('ScreenActive'));
%       PsychLVGL('ImageSetSrc', obj, img);
%
%   Errors: psychlvgl:Texture when the texture is a rectangle texture or is
%   stored transposed, which Psychtoolbox does unless textureOrientation is
%   1 or 2.
%
%   See also PSYCHLVGLOPEN, PSYCHLVGLCLOSE.

    GL_TEXTURE_2D = 3553;

    if nargin ~= 2
        error('psychlvgl:Usage', 'Usage: img = PsychLVGLImageFromTexture(win, tex)');
    end

    [glTex, target] = Screen('GetOpenGLTexture', win, tex);
    if target ~= GL_TEXTURE_2D
        error('psychlvgl:Texture', ...
              ['texture %d is not a GL_TEXTURE_2D texture (target 0x%X). Make it ' ...
               'with specialFlags 1: Screen(''MakeTexture'', win, M, [], 1, [], 1).'], ...
              tex, target);
    end

    % Psychtoolbox maps texel coordinates through the texture's orientation.
    % An upright texture stores the bottom row first, so the top left pixel
    % maps to v near 1. A transposed one, the MakeTexture default, maps it to
    % v near 0, and LVGL cannot transpose an image while it draws it.
    [~, ~, ~, v0] = Screen('GetOpenGLTexture', win, tex, 0, 0);
    if v0 < 0.5
        error('psychlvgl:Texture', ...
              ['texture %d is stored transposed. Make it with textureOrientation 1: ' ...
               'Screen(''MakeTexture'', win, M, [], 1, [], 1).'], tex);
    end

    rect = Screen('Rect', tex);
    img = PsychLVGL('ImageFromTexture', glTex, rect(3) - rect(1), rect(4) - rect(2));
end
