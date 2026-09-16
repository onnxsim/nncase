/* Copyright 2019-2021 Canaan Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include <fstream>
#include <nncase/data/dataset.h>
#include <string>

// patched locally: replaces opencv (imgcodecs/imgproc, and transitively
// libjpeg-turbo/libpng/jasper/zlib) with stb_image/stb_image_resize --
// this file only ever decodes a compressed image to interleaved RGB8 and
// box/bilinear-resizes it, both of which are exactly stb_image's job, at a
// fraction of the dependency weight (two vendored single-header files
// instead of a whole from-source OpenCV build).
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb_image_resize.h"

using namespace nncase;
using namespace nncase::data;

namespace
{
struct decoded_image
{
    std::vector<uint8_t> pixels; // interleaved RGB8, row-major
    int width;
    int height;
};

decoded_image decode_rgb(const std::vector<uint8_t> &src)
{
    int w, h, comp;
    auto *data = stbi_load_from_memory(src.data(), (int)src.size(), &w, &h, &comp, 3);
    if (!data)
        throw std::runtime_error(std::string("Failed to decode image: ") + stbi_failure_reason());

    decoded_image img { {}, w, h };
    img.pixels.assign(data, data + (size_t)w * (size_t)h * 3);
    stbi_image_free(data);
    return img;
}

std::vector<uint8_t> resize_rgb(const decoded_image &img, int dst_w, int dst_h)
{
    std::vector<uint8_t> out((size_t)dst_w * (size_t)dst_h * 3);
    if (!stbir_resize_uint8(img.pixels.data(), img.width, img.height, 0,
            out.data(), dst_w, dst_h, 0, 3))
        throw std::runtime_error("Failed to resize image");
    return out;
}

// Writes a resized RGB8 image into dest as either NHWC or NCHW, converting
// each channel with cvt(uint8_t). shape is the destination tensor shape
// (batch dim excluded by the caller, as in the original opencv version).
template <class T, class Cvt>
void write_image(const std::vector<uint8_t> &rgb, int dst_w, int dst_h, T *dest,
    const xt::dynamic_shape<size_t> &shape, const std::string &layout, Cvt cvt)
{
    if (layout == "NHWC")
    {
        auto channels = shape[3];
        for (int y = 0; y < dst_h; y++)
        {
            for (int x = 0; x < dst_w; x++)
            {
                auto i = (size_t)y * dst_w + x;
                auto *px = &rgb[i * 3];
                if (channels == 3)
                {
                    dest[i * 3] = cvt(px[0]);
                    dest[i * 3 + 1] = cvt(px[1]);
                    dest[i * 3 + 2] = cvt(px[2]);
                }
                else if (channels == 1)
                {
                    dest[i] = cvt(px[0]);
                }
                else
                {
                    throw std::runtime_error("Unsupported image channels: " + std::to_string(channels));
                }
            }
        }
    }
    else if (layout == "NCHW")
    {
        auto channels = shape[1];
        size_t channel_size = (size_t)dst_w * dst_h;
        for (int y = 0; y < dst_h; y++)
        {
            for (int x = 0; x < dst_w; x++)
            {
                auto i = (size_t)y * dst_w + x;
                auto *px = &rgb[i * 3];
                if (channels == 3)
                {
                    dest[i] = cvt(px[0]);
                    dest[i + channel_size] = cvt(px[1]);
                    dest[i + channel_size * 2] = cvt(px[2]);
                }
                else if (channels == 1)
                {
                    dest[i] = cvt(px[0]);
                }
                else
                {
                    throw std::runtime_error("Unsupported image channels: " + std::to_string(channels));
                }
            }
        }
    }
    else
    {
        throw std::runtime_error("Unsupported layout type!");
    }
}

std::pair<int, int> dest_size(const xt::dynamic_shape<size_t> &shape, const std::string &layout)
{
    // (width, height), matching the original code's cv::Size((int)shape[w_dim], (int)shape[h_dim])
    if (layout == "NHWC")
        return { (int)shape[2], (int)shape[1] };
    else if (layout == "NCHW")
        return { (int)shape[3], (int)shape[2] };
    throw std::runtime_error("Unsupported layout type!");
}
}

dataset::dataset(const std::filesystem::path &path, std::function<bool(const std::filesystem::path &)> file_filter, xt::dynamic_shape<size_t> input_shape, std::string input_layout)
    : input_shape_(std::move(input_shape)), input_layout_(input_layout)
{
    if (std::filesystem::is_directory(path))
    {
        for (auto &&filename : std::filesystem::recursive_directory_iterator(path))
        {
            if (file_filter(filename))
                filenames_.emplace_back(filename);
        }
    }
    else if (std::filesystem::exists(path))
    {
        if (file_filter(path))
            filenames_.emplace_back(path);
    }

    size_t samples = (filenames_.size() / batch_size()) * batch_size();
    filenames_.resize(samples);

    if (filenames_.empty())
        throw std::invalid_argument("Invalid dataset, should contain one file at least");
}

image_dataset::image_dataset(const std::filesystem::path &path, xt::dynamic_shape<size_t> input_shape, std::string input_layout)
    : dataset(
        path, [](const std::filesystem::path &filename) {
            int w, h, comp;
            return stbi_info(filename.string().c_str(), &w, &h, &comp) != 0;
        },
        std::move(input_shape), input_layout)
{
}

void image_dataset::process(const std::vector<uint8_t> &src, float *dest, const xt::dynamic_shape<size_t> &shape, std::string layout)
{
    auto img = decode_rgb(src);
    auto [dst_w, dst_h] = dest_size(shape, layout);
    auto resized = resize_rgb(img, dst_w, dst_h);
    write_image(resized, dst_w, dst_h, dest, shape, layout, [](uint8_t v) { return v / 255.0f; });
}

void image_dataset::process(const std::vector<uint8_t> &src, uint8_t *dest, const xt::dynamic_shape<size_t> &shape, std::string layout)
{
    auto img = decode_rgb(src);
    auto [dst_w, dst_h] = dest_size(shape, layout);
    auto resized = resize_rgb(img, dst_w, dst_h);
    write_image(resized, dst_w, dst_h, dest, shape, layout, [](uint8_t v) { return v; });
}

void image_dataset::process(const std::vector<uint8_t> &src, int8_t *dest, const xt::dynamic_shape<size_t> &shape, std::string layout)
{
    auto img = decode_rgb(src);
    auto [dst_w, dst_h] = dest_size(shape, layout);
    auto resized = resize_rgb(img, dst_w, dst_h);
    write_image(resized, dst_w, dst_h, dest, shape, layout, [](uint8_t v) { return (int8_t)v; });
}

raw_dataset::raw_dataset(const std::filesystem::path &path, xt::dynamic_shape<size_t> input_shape)
    : dataset(
        path, []([[maybe_unused]] const std::filesystem::path &filename) { return true; },
        std::move(input_shape), "")
{
}

void raw_dataset::process(const std::vector<uint8_t> &src, float *dest, const xt::dynamic_shape<size_t> &shape, [[maybe_unused]] std::string layout)
{
    auto expected_size = xt::compute_size(shape) * sizeof(float);
    auto actual_size = src.size();
    if (expected_size != actual_size)
    {
        throw std::runtime_error("Invalid dataset, file size should be "
            + std::to_string(expected_size) + "B, but got " + std::to_string(actual_size) + "B");
    }

    auto data = reinterpret_cast<const float *>(src.data());
    std::copy(data, data + actual_size / sizeof(float), dest);
}

void raw_dataset::process(const std::vector<uint8_t> &src, uint8_t *dest, const xt::dynamic_shape<size_t> &shape, [[maybe_unused]] std::string layout)
{
    auto expected_size = xt::compute_size(shape);
    auto actual_size = src.size();
    if (expected_size != actual_size)
    {
        throw std::runtime_error("Invalid dataset, file size should be "
            + std::to_string(expected_size) + "B, but got " + std::to_string(actual_size) + "B");
    }

    std::copy(src.begin(), src.end(), dest);
}

void raw_dataset::process(const std::vector<uint8_t> &src, int8_t *dest, const xt::dynamic_shape<size_t> &shape, [[maybe_unused]] std::string layout)
{
    auto expected_size = xt::compute_size(shape);
    auto actual_size = src.size();
    if (expected_size != actual_size)
    {
        throw std::runtime_error("Invalid dataset, file size should be "
            + std::to_string(expected_size) + "B, but got " + std::to_string(actual_size) + "B");
    }

    auto data = reinterpret_cast<const int8_t *>(src.data());
    std::copy(data, data + actual_size / sizeof(int8_t), dest);
}
