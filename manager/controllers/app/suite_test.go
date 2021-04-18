// Copyright 2020 IBM Corp.
// SPDX-License-Identifier: Apache-2.0

package app

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/ibm/the-mesh-for-data/manager/controllers/utils"
	"helm.sh/helm/v3/pkg/release"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	comv1alpha1 "github.com/datashim-io/datashim/src/dataset-operator/pkg/apis/com/v1alpha1"
	appapi "github.com/ibm/the-mesh-for-data/manager/apis/app/v1alpha1"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
	v1 "k8s.io/api/core/v1"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	"sigs.k8s.io/controller-runtime/pkg/envtest/printer"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	"github.com/ibm/the-mesh-for-data/manager/controllers/mockup"
	"github.com/ibm/the-mesh-for-data/pkg/helm"
	local "github.com/ibm/the-mesh-for-data/pkg/multicluster/local"
	"github.com/ibm/the-mesh-for-data/pkg/storage"
	"github.com/ibm/the-mesh-for-data/pkg/vault"
	// +kubebuilder:scaffold:imports
)

// These tests use Ginkgo (BDD-style Go testing framework). Refer to
// http://onsi.github.io/ginkgo/ to learn more about Ginkgo.

var cfg *rest.Config
var k8sClient client.Client
var mgr ctrl.Manager
var testEnv *envtest.Environment

func TestAPIs(t *testing.T) {
	RegisterFailHandler(Fail)

	RunSpecsWithDefaultAndCustomReporters(t,
		"Controller Suite",
		[]Reporter{printer.NewlineReporter{}})
}

var _ = BeforeSuite(func(done Done) {
	logf.SetLogger(zap.LoggerTo(GinkgoWriter, true))

	By("bootstrapping test environment")
	testEnv = &envtest.Environment{
		CRDDirectoryPaths: []string{
			filepath.Join("..", "..", "config", "crd", "bases"),
		},
	}

	utils.DefaultTestConfiguration(GinkgoT())

	var err error
	cfg, err = testEnv.Start()
	Expect(err).ToNot(HaveOccurred())
	Expect(cfg).ToNot(BeNil())

	err = appapi.AddToScheme(scheme.Scheme)
	Expect(err).NotTo(HaveOccurred())
	err = comv1alpha1.SchemeBuilder.AddToScheme(scheme.Scheme)
	Expect(err).NotTo(HaveOccurred())

	// +kubebuilder:scaffold:scheme

	if os.Getenv("USE_EXISTING_CONTROLLER") == "true" {
		logf.Log.Info("Using existing controller in existing cluster...")
		k8sClient, err = client.New(cfg, client.Options{Scheme: scheme.Scheme})
		Expect(err).ToNot(HaveOccurred())
	} else {
		// Mockup connectors
		go mockup.CreateTestCatalogConnector(GinkgoT())

		mgr, err = ctrl.NewManager(cfg, ctrl.Options{
			Scheme:             scheme.Scheme,
			MetricsBindAddress: "localhost:8086",
		})
		Expect(err).ToNot(HaveOccurred())

		// Setup application controller
		var clusterLister *mockup.ClusterLister
		policyCompiler := &mockup.MockPolicyCompiler{}
		conn, _ := vault.NewDummyConnection()
		err = NewM4DApplicationReconciler(mgr, "M4DApplication", conn, policyCompiler, clusterLister, storage.NewProvisionTest()).SetupWithManager(mgr)
		Expect(err).ToNot(HaveOccurred())

		// Setup blueprint controller
		fakeHelm := helm.NewFake(
			&release.Release{
				Name: "ra8afad067a6a96084dcb", // Release name is from arrow-flight module
				Info: &release.Info{Status: release.StatusDeployed},
			}, []*unstructured.Unstructured{},
		)
		err = NewBlueprintReconciler(mgr, "Blueprint", fakeHelm).SetupWithManager(mgr)
		Expect(err).ToNot(HaveOccurred())

		// Setup plotter controller
		clusterMgr, err := local.NewManager(mgr.GetClient(), "m4d-system")
		Expect(err).NotTo(HaveOccurred())
		Expect(clusterMgr).NotTo(BeNil())
		err = NewPlotterReconciler(mgr, "Plotter", clusterMgr).SetupWithManager(mgr)
		Expect(err).ToNot(HaveOccurred())

		go func() {
			err = mgr.Start(ctrl.SetupSignalHandler())
			Expect(err).ToNot(HaveOccurred())
		}()

		k8sClient = mgr.GetClient()
		Expect(k8sClient.Create(context.Background(), &v1.Namespace{
			ObjectMeta: metav1.ObjectMeta{
				Name: "m4d-system",
			},
		}))
		Expect(k8sClient.Create(context.Background(), &v1.Namespace{
			ObjectMeta: metav1.ObjectMeta{
				Name: "m4d-blueprints",
			},
		}))
		Expect(k8sClient.Create(context.Background(), &v1.ConfigMap{
			ObjectMeta: metav1.ObjectMeta{
				Name:      "cluster-metadata",
				Namespace: "m4d-system",
			},
			Data: map[string]string{
				"ClusterName":   "thegreendragon",
				"Zone":          "hobbiton",
				"Region":        "theshire",
				"VaultAuthPath": "kind",
			},
		}))
	}
	Expect(k8sClient).ToNot(BeNil())
	close(done)
}, 60)

var _ = AfterSuite(func() {
	By("tearing down the test environment")
	gexec.KillAndWait(5 * time.Second)
	err := testEnv.Stop()
	mockup.KillServer()
	Expect(err).ToNot(HaveOccurred())
})
