# from https://github.com/Homebrew/homebrew-core/blob/master/Formula/opam.rb#L24-L27

./configure --prefix=$PREFIX --with-vendored-deps && make && make test && make install

# if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-64" ]]; then
#   make libinstall
# fi
