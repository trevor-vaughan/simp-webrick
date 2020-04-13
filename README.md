# Recreate the Ruby puppet server

Forked from https://github.com/puppetlabs/puppet commit `fd4024d`

MASSIVE WORK IN PROGRESS...but seems to work :-D

## Steps for Running in minikube

* Install `minikube`
* `minikube start`
* Run a local registry
  * `kubectl create -f local_registry.yml`
  * `kubectl port-forward --namespace kube-system $(kubectl get pod -n kube-system | grep kube-registry-v0 | \awk '{print $1;}') 5000:5000`
* Create the container image
  * `buildah bud -t puppetmaster:latest -f Dockerfile`
* Update your `podman` configuration
  * Add `localhost` to the `registries` array of `[registries.insecure]` in `/etc/containers/registries.conf`
* Push the container image
  * `podman push localhost/puppetmaster localhost:5000/puppetmaster`
* Run the pod
  * `kubectl create -f puppetmaster.yml`

## TODO

* [] Autoscale puppetmaster compilers as a cluster
