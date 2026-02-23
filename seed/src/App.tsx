// routing
import Routes from 'routes';

// project imports
import Locales from 'ui-component/Locales';
import NavigationScroll from 'layout/NavigationScroll';
// import RTLLayout from 'ui-component/RTLLayout';
import Snackbar from 'ui-component/extended/Snackbar';
import ThemeCustomization from 'themes';
import Notistack from 'ui-component/third-party/Notistack';

// auth provider
import { JWTProvider as AuthProvider } from 'contexts/JWTContext';
// import { FirebaseProvider as AuthProvider } from 'contexts/FirebaseContext';
// import { AWSCognitoProvider as AuthProvider } from 'contexts/AWSCognitoContext';
// import { Auth0Provider as AuthProvider } from 'contexts/Auth0Context';

// ==============================|| APP ||============================== //

const App = () => (
    <ThemeCustomization>
        {/* RTL layout */}
        {/* <RTLLayout> */}
        <Locales>
            <NavigationScroll>
                <AuthProvider>
                    <>
                        <Notistack>
                            <Routes />
                            <Snackbar />
                        </Notistack>
                    </>
                </AuthProvider>
            </NavigationScroll>
        </Locales>
        {/* </RTLLayout> */}
    </ThemeCustomization>
);

export default App;
