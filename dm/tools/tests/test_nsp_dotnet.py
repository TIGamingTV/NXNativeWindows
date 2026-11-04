"""NSP script: Homebrew's dotnet wrapper must supply its runtime root to standalone apphosts.
No game files, keys or .NET installation needed."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)


class Dotnet(unittest.TestCase):
    def setUp(self):
        cm = mock.patch.dict(os.environ, {'PATH': '/tools/bin'}, clear=True)
        cm.__enter__(); self.addCleanup(cm.__exit__, None, None, None)

    def test_homebrew_runtime_reaches_explicit_and_inherited_children(self):
        root = '/external/Tools With Spaces/Cellar/dotnet/10.0.402/libexec'
        env = dict(os.environ, DOTNET_ROOT_X64='/caller/x64')
        out = f'Microsoft.AspNetCore.App 10.0.13 [{root}/shared/Microsoft.AspNetCore.App]\n' + \
              f'Microsoft.NETCore.App 10.0.13 [{root}/shared/Microsoft.NETCore.App]\n'
        with mock.patch.object(nsp.shutil, 'which', return_value='/tools/bin/dotnet') as which, \
             mock.patch.object(nsp.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, out)) as run:
            nsp.configure_dotnet(env)
            which.assert_called_once_with('dotnet', path='/tools/bin')
            self.assertIs(run.call_args.kwargs['env'], env)
        cmd = [sys.executable, '-c', 'import json, os; print(json.dumps(os.environ.get("DOTNET_ROOT")))']
        for child_env in (env, None):
            r = subprocess.run(cmd, env=child_env, capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(r.stdout), root)
        self.assertEqual(env['DOTNET_ROOT_X64'], '/caller/x64')

    def test_caller_root_wins(self):
        os.environ.update(DOTNET_ROOT='/caller/runtime', DOTNET_ROOT_ARM64='/caller/arm64')
        env = dict(os.environ)
        with mock.patch.object(nsp.subprocess, 'run') as run:
            nsp.configure_dotnet(env)
            run.assert_not_called()
        self.assertEqual(env, dict(os.environ))
        self.assertEqual(env['DOTNET_ROOT'], '/caller/runtime')
        self.assertEqual(env['DOTNET_ROOT_ARM64'], '/caller/arm64')

    def test_missing_dotnet_leaves_environment_untouched(self):
        env = dict(os.environ)
        with mock.patch.object(nsp.shutil, 'which', return_value=None), mock.patch.object(nsp.subprocess, 'run') as run:
            nsp.configure_dotnet(env)
            run.assert_not_called()
        self.assertEqual(env, dict(os.environ))

    def test_failed_or_malformed_probe_does_not_export_wrapper_directory(self):
        outputs = ('', 'Microsoft.AspNetCore.App 10.0.13 [/runtime/shared/Microsoft.AspNetCore.App]',
                   'Microsoft.NETCore.App 10.0.13 [/runtime/shared/Microsoft.NETCore.App',
                   'Microsoft.NETCore.App 10.0.13 [/not/a/runtime]')
        failures = (OSError('cannot execute dotnet'), subprocess.TimeoutExpired('dotnet', 10), subprocess.CalledProcessError(1, 'dotnet'))
        for result in (*outputs, *failures):
            with self.subTest(result=result):
                env = dict(os.environ)
                kw = {'side_effect': result} if isinstance(result, Exception) else {'return_value': subprocess.CompletedProcess([], 0, result)}
                with mock.patch.object(nsp.shutil, 'which', return_value='/homebrew/bin/dotnet'), mock.patch.object(nsp.subprocess, 'run', **kw):
                    nsp.configure_dotnet(env)
                self.assertNotIn('DOTNET_ROOT', env)
                self.assertNotIn('DOTNET_ROOT', os.environ)


class NxExtractBuild(unittest.TestCase):
    def test_one_build_per_source_key(self):   # the title probe's build serves the build folder, and a later run's build folder keeps its build until the sources or the SDK change
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            d, builds, sdk = Path(d), [], ['10.0.403']
            def build(t): builds.append(t); (t / 'nx_extract').write_text('exe'); (t / 'LibHac.dll').write_text('lib')
            def fingerprint(*items, env=None): return repr([i for i in items if i[0] == 'files']) + sdk[0]
            with mock.patch.object(nsp, 'fingerprint', fingerprint), mock.patch.dict(nsp._NX_BUILT, clear=True):
                probe = d / 'probe/tools/nx_extract/nx_extract'; work = d / 'work/tools/nx_extract/nx_extract'
                self.assertEqual(nsp.nx_extract_cached(REPO, probe, {}, build), probe)
                nsp.rmtree(d / 'probe')
                self.assertEqual(nsp.nx_extract_cached(REPO, work, {}, build), work)
                self.assertEqual(len(builds), 1); self.assertEqual((work.parent / 'LibHac.dll').read_text(), 'lib')
                nsp._NX_BUILT.clear()   # a new run
                nsp.nx_extract_cached(REPO, work, {}, build); self.assertEqual(len(builds), 1)
                sdk[0] = '10.0.500'; nsp.nx_extract_cached(REPO, work, {}, build); self.assertEqual(len(builds), 2)


if __name__ == '__main__': unittest.main()
