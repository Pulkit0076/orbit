// Copyright (c) 2020 The Orbit Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <absl/strings/str_format.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "OrbitBase/ReadFileToString.h"
#include "OrbitBase/SafeStrerror.h"
#include "OrbitBase/UniqueResource.h"

namespace orbit_base {

ErrorMessageOr<std::string> ReadFileToString(const std::filesystem::path& file_name) noexcept {
  auto fd = unique_resource(TEMP_FAILURE_RETRY(open(file_name.c_str(), O_RDONLY | O_CLOEXEC)),
                            [](int fd) {
                              if (fd != -1) close(fd);
                            });
  if (fd == -1) {
    return ErrorMessage(
        absl::StrFormat("Unable to read file \"%s\": %s", file_name.string(), SafeStrerror(errno)));
  }

  std::string result;

  // We want to avoid memory reallocations in case the file is relatively large.
  struct stat st {};
  if (fstat(fd, &st) != -1 && st.st_size > 0) {
    result.reserve(st.st_size);
  }

  std::array<char, BUFSIZ> buf{};
  ssize_t number_of_bytes;
  while ((number_of_bytes = TEMP_FAILURE_RETRY(read(fd, buf.data(), buf.size()))) > 0) {
    result.append(buf.data(), number_of_bytes);
  }

  // It is 0 if we reached end of file, -1 means an error has occurred
  if (number_of_bytes == -1) {
    return ErrorMessage(
        absl::StrFormat("Unable to read file \"%s\": %s", file_name.string(), SafeStrerror(errno)));
  }

  return result;
}

}  // namespace orbit_base