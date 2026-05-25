// SherpaOnnxC/shim.h —— umbrella header
//
// 单一职责：转发 sherpa-onnx 的 C API 头给 Swift 模块。
// 真正的头文件在 Vendor/sherpa-onnx/include/，由 Package.swift
// 的 cSettings.headerSearchPath 把那个目录加进搜索路径。

#include "sherpa-onnx/c-api/c-api.h"
