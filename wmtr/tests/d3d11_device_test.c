/* Run as an x86-64 executable under ARM64EC Wine with DXMT selected. Exercises
 * PE loading, the native Unix library, host device creation and a GPU readback.
 * Build: x86_64-w64-mingw32-gcc -Wall -Wextra d3d11_device_test.c -ld3d11 -ldxgi -o d3d11_device_test.exe
 */
#define COBJMACROS
#include <d3d11.h>
#include <stdio.h>
#include <string.h>

int main(void) {
  ID3D11Device *device = NULL;
  ID3D11DeviceContext *context = NULL;
  ID3D11Buffer *source = NULL, *staging = NULL;
  D3D_FEATURE_LEVEL level = 0;
  const D3D_FEATURE_LEVEL requested = D3D_FEATURE_LEVEL_11_0;
  const unsigned int expected[] = {0x12345678, 0xaabbccdd, 0x01020304, 0xffffffff};
  D3D11_BUFFER_DESC desc = {0};
  D3D11_SUBRESOURCE_DATA data = {expected, 0, 0};
  D3D11_MAPPED_SUBRESOURCE mapped = {0};
  const char *stage = "D3D11CreateDevice";
  int result = 1;
  HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0,
      &requested, 1, D3D11_SDK_VERSION, &device, &level, &context);
  setvbuf(stdout, NULL, _IONBF, 0);
  if (FAILED(hr)) goto done;
  printf("D3D11 device created: feature level %x\n", (unsigned int)level);
  desc.ByteWidth = sizeof expected;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_VERTEX_BUFFER;
  stage = "CreateBuffer(default)";
  hr = ID3D11Device_CreateBuffer(device, &desc, &data, &source);
  if (FAILED(hr)) goto done;
  desc.Usage = D3D11_USAGE_STAGING;
  desc.BindFlags = 0;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  stage = "CreateBuffer(staging)";
  hr = ID3D11Device_CreateBuffer(device, &desc, NULL, &staging);
  if (FAILED(hr)) goto done;
  ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)staging, (ID3D11Resource *)source);
  stage = "Map(readback)";
  hr = ID3D11DeviceContext_Map(context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped);
  if (FAILED(hr)) goto done;
  result = memcmp(expected, mapped.pData, sizeof expected) != 0;
  ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
  printf("D3D11 GPU readback: %s\n", result ? "FAIL" : "passed");
done:
  if (FAILED(hr)) fprintf(stderr, "%s failed: %08lx\n", stage, (unsigned long)hr);
  if (staging) ID3D11Buffer_Release(staging);
  if (source) ID3D11Buffer_Release(source);
  if (context) ID3D11DeviceContext_Release(context);
  if (device) ID3D11Device_Release(device);
  return result;
}
