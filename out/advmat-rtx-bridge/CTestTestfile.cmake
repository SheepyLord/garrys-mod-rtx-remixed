# CMake generated Testfile for 
# Source directory: H:/BACKUP_20260815/Modding/ipg/garrys-mod-rtx-remixed/source/advmat_rtx_bridge
# Build directory: H:/BACKUP_20260815/Modding/ipg/garrys-mod-rtx-remixed/out/advmat-rtx-bridge
# 
# This file includes the relevant testing commands required for 
# testing this directory and lists subdirectories to be tested as well.
if(CTEST_CONFIGURATION_TYPE MATCHES "^([Dd][Ee][Bb][Uu][Gg])$")
  add_test([=[advmat_rtx_writer_tests]=] "H:/BACKUP_20260815/Modding/ipg/garrys-mod-rtx-remixed/out/advmat-rtx-bridge/Debug/advmat_rtx_writer_tests.exe")
  set_tests_properties([=[advmat_rtx_writer_tests]=] PROPERTIES  _BACKTRACE_TRIPLES "H:/BACKUP_20260815/Modding/ipg/garrys-mod-rtx-remixed/source/advmat_rtx_bridge/CMakeLists.txt;34;add_test;H:/BACKUP_20260815/Modding/ipg/garrys-mod-rtx-remixed/source/advmat_rtx_bridge/CMakeLists.txt;0;")
elseif(CTEST_CONFIGURATION_TYPE MATCHES "^([Rr][Ee][Ll][Ee][Aa][Ss][Ee])$")
  add_test([=[advmat_rtx_writer_tests]=] "H:/BACKUP_20260815/Modding/ipg/garrys-mod-rtx-remixed/out/advmat-rtx-bridge/Release/advmat_rtx_writer_tests.exe")
  set_tests_properties([=[advmat_rtx_writer_tests]=] PROPERTIES  _BACKTRACE_TRIPLES "H:/BACKUP_20260815/Modding/ipg/garrys-mod-rtx-remixed/source/advmat_rtx_bridge/CMakeLists.txt;34;add_test;H:/BACKUP_20260815/Modding/ipg/garrys-mod-rtx-remixed/source/advmat_rtx_bridge/CMakeLists.txt;0;")
elseif(CTEST_CONFIGURATION_TYPE MATCHES "^([Mm][Ii][Nn][Ss][Ii][Zz][Ee][Rr][Ee][Ll])$")
  add_test([=[advmat_rtx_writer_tests]=] "H:/BACKUP_20260815/Modding/ipg/garrys-mod-rtx-remixed/out/advmat-rtx-bridge/MinSizeRel/advmat_rtx_writer_tests.exe")
  set_tests_properties([=[advmat_rtx_writer_tests]=] PROPERTIES  _BACKTRACE_TRIPLES "H:/BACKUP_20260815/Modding/ipg/garrys-mod-rtx-remixed/source/advmat_rtx_bridge/CMakeLists.txt;34;add_test;H:/BACKUP_20260815/Modding/ipg/garrys-mod-rtx-remixed/source/advmat_rtx_bridge/CMakeLists.txt;0;")
elseif(CTEST_CONFIGURATION_TYPE MATCHES "^([Rr][Ee][Ll][Ww][Ii][Tt][Hh][Dd][Ee][Bb][Ii][Nn][Ff][Oo])$")
  add_test([=[advmat_rtx_writer_tests]=] "H:/BACKUP_20260815/Modding/ipg/garrys-mod-rtx-remixed/out/advmat-rtx-bridge/RelWithDebInfo/advmat_rtx_writer_tests.exe")
  set_tests_properties([=[advmat_rtx_writer_tests]=] PROPERTIES  _BACKTRACE_TRIPLES "H:/BACKUP_20260815/Modding/ipg/garrys-mod-rtx-remixed/source/advmat_rtx_bridge/CMakeLists.txt;34;add_test;H:/BACKUP_20260815/Modding/ipg/garrys-mod-rtx-remixed/source/advmat_rtx_bridge/CMakeLists.txt;0;")
else()
  add_test([=[advmat_rtx_writer_tests]=] NOT_AVAILABLE)
endif()
