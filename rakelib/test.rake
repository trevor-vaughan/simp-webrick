namespace :test do
  desc "Run integration tests; starts the compose stack automatically if not already up"
  task :integration do
    # Probe the CA endpoint.  If it answers the stack is already running, so run
    # tests against it without touching its lifecycle.  Otherwise pass --up so
    # integration.sh manages start and tear-down itself.
    stack_up = system(
      'curl', '-sf', '--max-time', '3',
      'http://localhost:8141/puppet-ca/v1/certificate/ca',
      out: File::NULL, err: File::NULL
    )

    exec 'test/integration.sh', *(stack_up ? [] : ['--up'])
  end

  desc "Force a fresh compose stack: start, run integration tests, tear down"
  task 'integration:full' do
    exec 'test/integration.sh', '--up'
  end

  desc "Run integration tests against Minikube; deploys the stack automatically if not already healthy"
  task 'integration:k8s' do
    sh 'k8s/minikube-deploy.sh'
    exec 'test/integration.sh', '--k8s'
  end
end

desc "Run all tests (starts compose stack automatically if not already up)"
task test: ['test:integration']
