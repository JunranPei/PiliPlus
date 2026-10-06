cmake_minimum_required(VERSION 3.22.1)
project(pip_buffer_geometry LANGUAGES CXX)
add_library(pip_buffer_geometry SHARED pip_buffer_geometry.cpp)
target_link_libraries(pip_buffer_geometry android)
