package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"

	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/containerservice/armcontainerservice/v2"
	"golang.org/x/oauth2/google"
	"google.golang.org/api/idtoken"
	"google.golang.org/api/option"
)

func googleIDToken(ctx context.Context) (string, error) {
	credentials, err := google.FindDefaultCredentials(ctx)
	if err != nil {
		return "", err
	}

	ts, err := idtoken.NewTokenSource(ctx, "api://AzureADTokenExchange", option.WithCredentials(credentials))
	if err != nil {
		return "", fmt.Errorf("failed to create NewTokenSource: %w", err)
	}

	token, err := ts.Token()
	if err != nil {
		return "", fmt.Errorf("failed to receive google token: %w", err)
	}
	log.Println("Token type:", token.Type())
	return token.AccessToken, nil
}

func handler(w http.ResponseWriter, req *http.Request) {

	// Exchange identity token for Azure AD access token
	tenantID := os.Getenv("TENANT_ID")
	clientID := os.Getenv("CLIENT_ID")

	cred, err := azidentity.NewClientAssertionCredential(tenantID, clientID, googleIDToken, &azidentity.ClientAssertionCredentialOptions{})
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte(err.Error()))
		return
	}

	// Get cluster description
	subscriptionID := os.Getenv("SUBSCRIPTION_ID")
	resourceGroup := os.Getenv("RESOURCE_GROUP")
	clusterName := os.Getenv("CLUSTER_NAME")
	aksClientFactory, err := armcontainerservice.NewClientFactory(subscriptionID, cred, nil)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte(fmt.Sprintf("error creating client: %v", err)))
		return
	}
	aksClient := aksClientFactory.NewManagedClustersClient()
	clusterData, err := aksClient.Get(context.Background(), resourceGroup, clusterName, nil)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte(fmt.Sprintf("error getting cluster data: %v", err)))
		return
	}

	data, _ := clusterData.MarshalJSON()
	w.WriteHeader(http.StatusOK)
	w.Write(data)
}

func main() {
	http.HandleFunc("/", handler)
	if err := http.ListenAndServe(":8080", nil); err != nil {
		log.Fatal(err)
	}
}
